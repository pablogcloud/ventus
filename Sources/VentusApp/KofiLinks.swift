import Foundation

/// Where the tip button sends people, and why it is shaped this way.
///
/// Ko-fi has no URL parameter that presets a tip amount. This is not an
/// assumption — `https://ko-fi.com/pablogv?amount=20` was loaded against the
/// live site and the query string is stripped on navigation. The one documented
/// way a Ko-fi link can carry a price is a **Shop item**, reachable at
/// `ko-fi.com/s/<code>`, which has a fixed amount set when the item is created.
///
/// So each slider stop maps to one shop item. Until a code is filled in below
/// the button falls back to the profile page and the copy stops promising an
/// amount it cannot actually set — a button reading "Tip $20" that opens a page
/// defaulting to something else is worse than no number at all.
///
/// To make the slider bind real prices, create four Shop items on Ko-fi priced
/// $5 / $10 / $20 / $35, then paste each item's code — the part after
/// `ko-fi.com/s/` in its share link — into `shopItemCodes`.
enum KofiLinks {
    static let profile = URL(string: "https://ko-fi.com/pablogv")!

    /// The tip tiers, which are also the cup's four keyframes.
    static let tiers = [5, 10, 20, 35]

    /// Tier amount → Ko-fi Shop item code. Empty until the items exist.
    static let shopItemCodes: [Int: String] = [:]

    /// True when this tier resolves to a fixed-price checkout rather than the
    /// generic profile page.
    static func hasFixedPrice(_ tier: Int) -> Bool {
        shopItemCodes[tier] != nil
    }

    static func url(forTier tier: Int) -> URL {
        guard let code = shopItemCodes[tier],
              let url = URL(string: "https://ko-fi.com/s/\(code)")
        else { return profile }
        return url
    }
}
