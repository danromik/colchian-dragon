import CoreGraphics

/// An animation for the About panel. Each design tells the same story: the story fades in, the
/// Colchian dragon flies in from the left and turns to face the viewer with unblinking eyes, and the
/// credits appear while it keeps moving gently.
protocol AboutArtwork {
    /// The canvas size the artwork is designed for, in points.
    static var size: CGSize { get }

    /// Draws the artwork `time` seconds after the About panel opened, into `rect` (unflipped): the story, then
    /// the tagline, then the credits. AppKit's current graphics context draws into `ctx` too, for artwork that
    /// draws text with AppKit.
    static func draw(time: Double, in rect: CGRect, context ctx: CGContext, story: String, tagline: String, credits: String)
}
