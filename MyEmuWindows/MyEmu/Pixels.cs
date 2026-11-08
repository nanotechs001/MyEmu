namespace MyEmu;

public static class Pixels
{
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
