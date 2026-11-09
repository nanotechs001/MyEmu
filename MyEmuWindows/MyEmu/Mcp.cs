using System.IO;
using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace MyEmu;

/// One piece of a tool's answer.
public abstract record McpContent
{
    public abstract JsonObject Json();
}

public sealed record McpText(string Text) : McpContent
{
    public override JsonObject Json() => new() { ["type"] = "text", ["text"] = Text };
}

public sealed record McpImage(byte[] Data, string MimeType) : McpContent
{
    public override JsonObject Json() => new() { ["type"] = "image", ["data"] = Convert.ToBase64String(Data), ["mimeType"] = MimeType };
}

public sealed record McpTool(string Name, string Description, JsonObject InputSchema);

/// A tool that failed in a way the AI should read (sent as a tool result, not a protocol error).
public sealed class McpToolError(string message) : Exception(message);

public sealed class McpUnknownTool(string name) : Exception(name);

/// Answers MCP's JSON-RPC messages: the handshake, ping, and listing and calling tools (Mac: MCPProtocol.swift).
public sealed class McpDispatcher(string serverName, string serverVersion, string instructions,
    IReadOnlyList<McpTool> tools, Func<string, JsonObject, Task<IReadOnlyList<McpContent>>> call)
{
    /// Newest first; a client asking for one of these gets it, anything else gets the newest.
    public static readonly string[] ProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"];
    /// Readable text for the AI: no  escapes for quotes or non-ASCII (Mac: .withoutEscapingSlashes).
    public static readonly JsonSerializerOptions Json = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// The reply to a JSON-RPC message (or batch); null when there's nothing to answer (a
    /// notification or a response), which HTTP sends as 202 Accepted.
    public async Task<string?> HandleAsync(string body)
    {
        JsonNode? message;
        try { message = JsonNode.Parse(body); }
        catch (JsonException) { return Error(null, -32700, "Parse error").ToJsonString(McpDispatcher.Json); }
        if (message is not JsonArray batch) return (await ReplyAsync(message))?.ToJsonString(McpDispatcher.Json);
        var replies = new JsonArray();
        foreach (var item in batch)
            if (await ReplyAsync(item) is { } reply) replies.Add(reply);
        return replies.Count == 0 ? null : replies.ToJsonString(McpDispatcher.Json);
    }

    async Task<JsonObject?> ReplyAsync(JsonNode? message)
    {
        if (message is not JsonObject m || m["method"]?.GetValueKind() != JsonValueKind.String) return null; // a response from the client
        if (!m.ContainsKey("id")) return null; // a notification, e.g. notifications/initialized
        var id = m["id"]?.DeepClone();
        var method = (string)m["method"]!;
        var parameters = m["params"] as JsonObject ?? [];
        switch (method)
        {
            case "initialize":
                var asked = parameters["protocolVersion"]?.GetValueKind() == JsonValueKind.String ? (string)parameters["protocolVersion"]! : null;
                return Result(id, new JsonObject
                {
                    ["protocolVersion"] = asked != null && ProtocolVersions.Contains(asked) ? asked : ProtocolVersions[0],
                    ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = false } },
                    ["serverInfo"] = new JsonObject { ["name"] = serverName, ["version"] = serverVersion },
                    ["instructions"] = instructions,
                });
            case "ping":
                return Result(id, []);
            case "tools/list":
                return Result(id, new JsonObject
                {
                    ["tools"] = new JsonArray(tools.Select(t => (JsonNode)new JsonObject
                    {
                        ["name"] = t.Name, ["description"] = t.Description, ["inputSchema"] = t.InputSchema.DeepClone(),
                    }).ToArray()),
                });
            case "tools/call":
                if (parameters["name"]?.GetValueKind() != JsonValueKind.String) return Error(id, -32602, "Missing tool name");
                try
                {
                    var content = await call((string)parameters["name"]!, parameters["arguments"] as JsonObject ?? []);
                    return Result(id, new JsonObject { ["content"] = new JsonArray(content.Select(c => (JsonNode)c.Json()).ToArray()), ["isError"] = false });
                }
                catch (McpUnknownTool e) { return Error(id, -32602, $"Unknown tool: {e.Message}"); }
                catch (Exception e)
                {
                    return Result(id, new JsonObject { ["content"] = new JsonArray(new McpText(e.Message).Json()), ["isError"] = true });
                }
            default:
                return Error(id, -32601, $"Method not found: {method}");
        }
    }

    static JsonObject Result(JsonNode? id, JsonObject result) => new() { ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = result };

    public static JsonObject Error(JsonNode? id, int code, string message) =>
        new() { ["jsonrpc"] = "2.0", ["id"] = id, ["error"] = new JsonObject { ["code"] = code, ["message"] = message } };
}

/// MCP's Streamable HTTP transport, the simple way (Mac: MCPServer.swift): each POST to /mcp carries one
/// JSON-RPC message and gets one JSON reply (no event stream, no sessions). Loopback only.
public sealed class McpHttpServer : IAsyncDisposable
{
    public const int Port = 8765;
    public const string Path = "/mcp";
    public static string Url => $"http://127.0.0.1:{Port}{Path}";
    /// MCP requests are small; anything bigger is refused.
    const int MaxBodyBytes = 1 << 20;

    readonly WebApplication app;
    McpHttpServer(WebApplication app) => this.app = app;

    public static async Task<McpHttpServer> StartAsync(McpDispatcher dispatcher)
    {
        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions { ContentRootPath = AppContext.BaseDirectory });
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(k =>
        {
            k.Listen(IPAddress.Loopback, Port);
            k.Limits.MaxRequestBodySize = MaxBodyBytes;
        });
        var app = builder.Build();
        app.Run(async context =>
        {
            string body;
            try { body = await new StreamReader(context.Request.Body).ReadToEndAsync(); }
            catch (BadHttpRequestException) { context.Response.StatusCode = 413; return; } // too big
            var (status, reply) = await RespondAsync(context.Request.Method, context.Request.Path, context.Request.Headers.Origin, body, dispatcher);
            context.Response.StatusCode = status;
            if (status == 405) context.Response.Headers.Allow = "POST";
            if (reply == null) return;
            context.Response.ContentType = "application/json; charset=utf-8";
            await context.Response.WriteAsync(reply);
        });
        await app.StartAsync();
        return new McpHttpServer(app);
    }

    /// Routing and the browser guard; the dispatcher does the rest.
    public static async Task<(int Status, string? Body)> RespondAsync(string method, string path, string? origin, string body, McpDispatcher dispatcher)
    {
        // A web page can reach a localhost port through DNS rebinding; MCP says to check Origin.
        if (!string.IsNullOrEmpty(origin) && !IsLocal(origin)) return (403, null);
        if (path != Path) return (404, null);
        if (method != "POST") return (405, null); // no event stream (GET), no sessions (DELETE)
        return await dispatcher.HandleAsync(body) is { } reply ? (200, reply) : (202, null);
    }

    public static bool IsLocal(string origin) =>
        Uri.TryCreate(origin, UriKind.Absolute, out var uri) && uri.Host is "localhost" or "127.0.0.1" or "[::1]" or "::1";

    public async ValueTask DisposeAsync()
    {
        await app.StopAsync();
        await app.DisposeAsync();
    }
}
