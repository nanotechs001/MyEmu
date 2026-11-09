using System.Text.Json.Nodes;
using MyEmu;
using Xunit;

/// Mac: MCPTests.swift.
public class McpTests
{
    static McpDispatcher Dispatcher(Func<string, JsonObject, Task<IReadOnlyList<McpContent>>>? call = null) =>
        new("Test", "1", "Testing.", [new McpTool("echo", "Echoes", new JsonObject { ["type"] = "object" })],
            call ?? ((_, _) => Task.FromResult<IReadOnlyList<McpContent>>([new McpText("ok")])));

    static async Task<JsonNode?> Send(string message, McpDispatcher dispatcher) =>
        await dispatcher.HandleAsync(message) is { } reply ? JsonNode.Parse(reply) : null;

    [Fact]
    public async Task InitializeAgreesOnAKnownProtocolVersion()
    {
        var known = await Send("""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}""", Dispatcher());
        Assert.Equal("2025-03-26", (string?)known?["result"]?["protocolVersion"]);
        Assert.NotNull(known?["result"]?["capabilities"]?["tools"]);
        Assert.Equal(1, (int?)known?["id"]);
        var unknown = await Send("""{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}""", Dispatcher());
        Assert.Equal(McpDispatcher.ProtocolVersions[0], (string?)unknown?["result"]?["protocolVersion"]);
    }

    [Fact]
    public async Task NotificationsGetNoReply() =>
        Assert.Null(await Send("""{"jsonrpc":"2.0","method":"notifications/initialized"}""", Dispatcher()));

    [Fact]
    public async Task ToolsAreListedAndCalled()
    {
        var list = await Send("""{"jsonrpc":"2.0","id":1,"method":"tools/list"}""", Dispatcher());
        Assert.Equal("""[{"name":"echo","description":"Echoes","inputSchema":{"type":"object"}}]""", list?["result"]?["tools"]?.ToJsonString());
        var called = await Send("""{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{}}}""", Dispatcher());
        Assert.Equal("""[{"type":"text","text":"ok"}]""", called?["result"]?["content"]?.ToJsonString());
        Assert.False((bool?)called?["result"]?["isError"]);
    }

    [Fact]
    public async Task FailuresAreReportedTheWayMcpSays()
    {
        var failing = Dispatcher((name, _) => name == "echo" ? throw new McpToolError("Not running.") : throw new McpUnknownTool(name));
        var toolError = await Send("""{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo"}}""", failing);
        Assert.True((bool?)toolError?["result"]?["isError"]); // a tool's own failure is a result the AI reads
        Assert.Equal("""[{"type":"text","text":"Not running."}]""", toolError?["result"]?["content"]?.ToJsonString());
        var unknownTool = await Send("""{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nope"}}""", failing);
        Assert.Equal(-32602, (int?)unknownTool?["error"]?["code"]);
        var unknownMethod = await Send("""{"jsonrpc":"2.0","id":3,"method":"nope"}""", Dispatcher());
        Assert.Equal(-32601, (int?)unknownMethod?["error"]?["code"]);
        var garbage = await Send("{", Dispatcher());
        Assert.Equal(-32700, (int?)garbage?["error"]?["code"]);
    }

    [Fact]
    public async Task OnlyLocalPagesMayCallAndOnlyPostToMcp()
    {
        Assert.True(McpHttpServer.IsLocal("http://localhost:6274"));
        Assert.True(McpHttpServer.IsLocal("http://127.0.0.1"));
        Assert.False(McpHttpServer.IsLocal("https://evil.example"));
        Assert.False(McpHttpServer.IsLocal("null"));
        const string ping = """{"jsonrpc":"2.0","id":1,"method":"ping"}""";
        Assert.Equal(403, (await McpHttpServer.RespondAsync("POST", "/mcp", "https://evil.example", ping, Dispatcher())).Status);
        Assert.Equal(404, (await McpHttpServer.RespondAsync("POST", "/other", null, ping, Dispatcher())).Status);
        Assert.Equal(405, (await McpHttpServer.RespondAsync("GET", "/mcp", null, "", Dispatcher())).Status);
        Assert.Equal(200, (await McpHttpServer.RespondAsync("POST", "/mcp", "http://localhost:6274", ping, Dispatcher())).Status);
    }

    [Fact]
    public void TypedTextIsQuotedForAndroidsShell()
    {
        Assert.Equal("input text 'hello%sworld'", MyEmuMcp.InputTextCommand("hello world"));
        Assert.Equal("input text 'it'\\''s%s$HOME;%srm'", MyEmuMcp.InputTextCommand("it's $HOME; rm"));
        Assert.Throws<McpToolError>(() => MyEmuMcp.InputTextCommand(""));
        Assert.Throws<McpToolError>(() => MyEmuMcp.InputTextCommand("two\nlines"));
        Assert.Throws<McpToolError>(() => MyEmuMcp.InputTextCommand("café"));
    }

    [Fact]
    public void EveryToolNeedsAnInstanceExceptTheList()
    {
        foreach (var tool in MyEmuMcp.Tools.Where(t => t.Name != "list_instances"))
            Assert.Contains("instance", ((JsonArray)tool.InputSchema["required"]!).Select(n => (string?)n));
        Assert.Equal(MyEmuMcp.Tools.Length, MyEmuMcp.Tools.Select(t => t.Name).Distinct().Count());
    }

    [Fact]
    public void ScreenshotsShrinkToFitAndKeepTheScale()
    {
        var shot = Screenshot.FromRgba(new byte[2400 * 1080 * 4], 2400, 1080, 1280);
        Assert.Equal((1280, 576), (shot.Width, shot.Height));
        Assert.Equal(1280.0 / 2400.0, shot.Scale, 3);
        var small = Screenshot.FromRgba(new byte[800 * 600 * 4], 800, 600, 1280);
        Assert.Equal((800, 600, 1.0), (small.Width, small.Height, small.Scale)); // never enlarged
        Assert.Equal(0xFF, small.Jpeg[0]); // JPEG
    }
}
