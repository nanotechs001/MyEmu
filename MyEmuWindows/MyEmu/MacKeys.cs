using System.Windows.Input;

namespace MyEmu;

/// Windows keys → the Mac virtual key codes keymaps are saved with (ANSI positions, as Mac kVK_*),
/// plus the label MyEmu draws on the key. Keys not listed can't be mapped.
public static class MacKeys
{
    static readonly Dictionary<Key, (ushort Code, string Label)> Table = Build();

    static Dictionary<Key, (ushort, string)> Build()
    {
        var t = new Dictionary<Key, (ushort, string)>();
        ushort[] letters = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]; // A…Z
        for (var i = 0; i < 26; i++) t[Key.A + i] = (letters[i], ((char)('A' + i)).ToString());
        ushort[] digits = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]; // 0…9
        for (var i = 0; i < 10; i++) t[Key.D0 + i] = (digits[i], i.ToString());
        ushort[] pad = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]; // keypad 0…9
        for (var i = 0; i < 10; i++) t[Key.NumPad0 + i] = (pad[i], "N" + i);
        ushort[] f = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]; // F1…F12
        for (var i = 0; i < 12; i++) t[Key.F1 + i] = (f[i], "F" + (i + 1));
        (Key, ushort, string)[] rest =
        [
            (Key.Space, 49, "Space"), (Key.Enter, 36, "↩"), (Key.Tab, 48, "⇥"), (Key.Back, 51, "⌫"), (Key.Escape, 53, "Esc"),
            (Key.Delete, 117, "Del"), (Key.Home, 115, "Home"), (Key.End, 119, "End"), (Key.PageUp, 116, "PgUp"), (Key.PageDown, 121, "PgDn"),
            (Key.Left, 123, "←"), (Key.Right, 124, "→"), (Key.Down, 125, "↓"), (Key.Up, 126, "↑"),
            (Key.OemMinus, 27, "-"), (Key.OemPlus, 24, "="), (Key.OemOpenBrackets, 33, "["), (Key.OemCloseBrackets, 30, "]"),
            (Key.OemSemicolon, 41, ";"), (Key.OemQuotes, 39, "'"), (Key.OemComma, 43, ","), (Key.OemPeriod, 47, "."),
            (Key.OemQuestion, 44, "/"), (Key.OemPipe, 42, "\\"), (Key.OemTilde, 50, "`"),
            (Key.Decimal, 65, "N."), (Key.Multiply, 67, "N*"), (Key.Add, 69, "N+"), (Key.Divide, 75, "N/"), (Key.Subtract, 78, "N-"),
        ];
        // No Shift/Ctrl/Alt/Caps Lock: the Mac can't map modifiers (they never arrive as key presses), and
        // Alt is the editor's "place joystick" modifier.
        foreach (var (key, code, label) in rest) t[key] = (code, label);
        return t;
    }

    public static (ushort Code, string Label)? From(Key key) => Table.TryGetValue(key, out var v) ? v : null;
}
