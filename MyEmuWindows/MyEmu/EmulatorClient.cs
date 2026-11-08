using System.IO;
using System.Threading.Channels;
using Android.Emulation.Control;
using Grpc.Core;
using Grpc.Net.Client;

namespace MyEmu;

/// Talks to the engine over gRPC: frames in through shared memory, input out in order. Mirrors EmulatorClient.swift.
public sealed class EmulatorClient : IDisposable
{
    /// Mid-range of the guest touchscreen's 0...1024 pressure axis.
    const int FingerPressure = 512;

    readonly GrpcChannel channel;
    readonly EmulatorController.EmulatorControllerClient controller;
    readonly Metadata metadata;
    readonly Channel<Func<Task>> input = Channel.CreateUnbounded<Func<Task>>(new() { SingleReader = true });

    public EmulatorClient(int port, string token)
    {
        // Loopback only; the engine also wants our token on every call.
        channel = GrpcChannel.ForAddress($"http://127.0.0.1:{port}",
            new GrpcChannelOptions { MaxReceiveMessageSize = 64 * 1024 * 1024 });
        controller = new EmulatorController.EmulatorControllerClient(channel);
        metadata = new Metadata { { "authorization", $"Bearer {token}" } };
        _ = Task.Run(PumpInputAsync);
    }

    public void Dispose()
    {
        input.Writer.TryComplete();
        channel.Dispose();
    }

    /// A single consumer keeps down/drag/up events in order.
    async Task PumpInputAsync()
    {
        await foreach (var send in input.Reader.ReadAllAsync())
        {
            try { await send(); }
            catch (Exception e) { System.Diagnostics.Debug.WriteLine($"Input event failed: {e.Message}"); }
        }
    }

    /// Pressure 0 lifts the finger.
    public void Touch(int id, int x, int y, bool pressed)
    {
        var e = new TouchEvent();
        e.Touches.Add(new Touch { Identifier = id, X = x, Y = y, Pressure = pressed ? FingerPressure : 0 });
        input.Writer.TryWrite(async () => await controller.sendTouchAsync(e, metadata));
    }

    /// A Windows scan code (0xE0xx for extended keys), what the engine's "Win" code type expects.
    public void Key(int scanCode, bool down) =>
        input.Writer.TryWrite(async () => await controller.sendKeyAsync(new KeyboardEvent
        {
            CodeType = KeyboardEvent.Types.KeyCodeType.Win, KeyCode = scanCode,
            EventType = down ? KeyboardEvent.Types.KeyEventType.Keydown : KeyboardEvent.Types.KeyEventType.Keyup,
        }, metadata));

    /// A full press of an Android navigation key (Linux evdev code).
    public void AndroidKey(int evdevCode) =>
        input.Writer.TryWrite(async () => await controller.sendKeyAsync(new KeyboardEvent
        {
            CodeType = KeyboardEvent.Types.KeyCodeType.Evdev, KeyCode = evdevCode,
            EventType = KeyboardEvent.Types.KeyEventType.Keypress,
        }, metadata));

    /// Streams frames until cancelled. The engine writes pixels straight into `buffer` instead of
    /// sending ~6 MB per frame over gRPC; if it sends them anyway, they're copied in.
    public async Task StreamFramesAsync(FrameBuffer buffer, DeviceSize size, Action<int, int> onFrame, CancellationToken cancel)
    {
        var format = new ImageFormat
        {
            Format = ImageFormat.Types.ImgFormat.Rgba8888, Width = (uint)size.Width, Height = (uint)size.Height,
            Transport = new ImageTransport { Channel = ImageTransport.Types.TransportChannel.Mmap, Handle = buffer.Handle },
        };
        using var call = controller.streamScreenshot(format, metadata, cancellationToken: cancel);
        await foreach (var frame in call.ResponseStream.ReadAllAsync(cancel))
        {
            int w = (int)frame.Format.Width, h = (int)frame.Format.Height, bytes = w * h * 4;
            if (w <= 0 || h <= 0 || bytes > buffer.Length) continue;            if (!frame.Image_.IsEmpty) // protobuf names the `image` field Image_ (clashes with the class)
            {
                if (frame.Image_.Length < bytes) continue;
                buffer.CopyFrom(frame.Image_.Span[..bytes]);
            }
            else buffer.ReadFrame(bytes);            onFrame(w, h);
        }
    }
}

/// A file the engine writes each frame into (MMAP transport). On Windows neither a mapped view of ours
/// nor a handle we keep open sees the engine's writes (only a freshly opened handle does), so each
/// frame is read back through a new handle (from the file cache, ~1 ms for 1600×900) into `Pixels`.
public sealed class FrameBuffer : IDisposable
{
    readonly string path;
    public byte[] Pixels { get; }
    public int Length => Pixels.Length;
    /// Lock while reading or using `Pixels`.
    public object Sync { get; } = new();
    /// The engine strips "file://", so file:///C:/... would leave "/C:/...".
    public string Handle => "file://" + path;

    public FrameBuffer(int capacity)
    {
        Pixels = new byte[capacity];
        path = Path.Combine(Path.GetTempPath(), $"myemu-frames-{System.Environment.ProcessId}-{Guid.NewGuid():N}.rgba");
        using var file = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);
        file.SetLength(capacity);
    }

    public void ReadFrame(int bytes)
    {
        using var handle = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        lock (Sync) RandomAccess.Read(handle, Pixels.AsSpan(0, bytes), 0);
    }

    public void CopyFrom(ReadOnlySpan<byte> source)
    {
        lock (Sync) source.CopyTo(Pixels);
    }

    public void Dispose()
    {
        try { File.Delete(path); } catch (IOException) { } // engine still has it open; it's in %TEMP% anyway
    }
}
