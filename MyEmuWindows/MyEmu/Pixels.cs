using System.Runtime.Intrinsics;

namespace MyEmu;

public static class Pixels
{
    static readonly Vector128<byte> SwapRB = Vector128.Create((byte)2, 1, 0, 3, 6, 5, 4, 7, 10, 9, 8, 11, 14, 13, 12, 15);

    /// The engine sends RGBA; WPF draws BGRA. 16 bytes (4 pixels) per step.
    public static void RgbaToBgra(ReadOnlySpan<byte> source, Span<byte> destination)
    {
        int i = 0, n = Math.Min(source.Length, destination.Length) & ~3;
        for (; i + 16 <= n; i += 16)
            Vector128.Shuffle(Vector128.Create(source.Slice(i, 16)), SwapRB).CopyTo(destination.Slice(i, 16));
        for (; i < n; i += 4)
        {
            destination[i] = source[i + 2]; destination[i + 1] = source[i + 1];
            destination[i + 2] = source[i]; destination[i + 3] = source[i + 3];
        }
    }

    /// A point in a view showing the screen aspect-fit, in device pixels; null in the letterbox bars.
    public static (int X, int Y)? DevicePoint(double x, double y, double viewWidth, double viewHeight, DeviceSize size)
    {
        var scale = Math.Min(viewWidth / size.Width, viewHeight / size.Height);
        if (scale <= 0) return null;
        var dx = (x - (viewWidth - size.Width * scale) / 2) / scale;
        var dy = (y - (viewHeight - size.Height * scale) / 2) / scale;
        return dx >= 0 && dy >= 0 && dx < size.Width && dy < size.Height ? ((int)dx, (int)dy) : null;
    }
}
