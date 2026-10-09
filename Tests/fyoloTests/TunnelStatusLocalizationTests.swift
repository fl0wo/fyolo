import XCTest

@testable import fyolo

/// That the tunnel's failure messages actually resolve to a translation.
///
/// `scripts/check-strings.sh` cannot answer this: it skips interpolated
/// `localized("…")` calls, because the key they produce carries a format
/// specifier whose type the scan can't infer from the text. So the one thing
/// that can go wrong here — Swift generating `%lld` where the catalog says
/// `%d`, or `%@` where it says `%1$@` — is exactly what nothing else checks,
/// and it fails silently by falling back to English.
///
/// Each case rebuilds the interpolation the way `TunnelManager` writes it, then
/// asks for zh-Hans explicitly. A mismatched key returns the English source
/// instead, so the assertion is on the translation itself.
final class TunnelStatusLocalizationTests: XCTestCase {
    /// The `zh-Hans.lproj` inside the resource bundle, resolved as its own
    /// bundle. `String(localized:locale:)` is not enough on its own: `locale`
    /// steers how the interpolations are formatted, while the *table* still
    /// comes from the bundle's own language resolution against the tester's
    /// preferred languages — so on an English Mac it reads en.lproj and every
    /// assertion here would pass against the English source it is meant to
    /// catch.
    private lazy var chineseBundle: Bundle? = {
        Bundle.fyoloResources
            .path(forResource: "zh-Hans", ofType: "lproj")
            .flatMap(Bundle.init(path:))
    }()

    private func zh(_ key: String.LocalizationValue) throws -> String {
        let bundle = try XCTUnwrap(chineseBundle, "zh-Hans.lproj is missing from the resource bundle")
        return String(localized: key, bundle: bundle, locale: Locale(identifier: "zh-Hans"))
    }

    func testTheCustomRelayHintIsTranslated() throws {
        XCTAssertEqual(
            try zh("set a command and URL pattern for the custom relay"),
            "为自定义中继设置命令和 URL 模式")
    }

    func testTheInstallFailureIsTranslated() throws {
        let binary = "tunelo"
        let reason = "network down"
        XCTAssertEqual(
            try zh("couldn’t install \(binary): \(reason)"),
            "无法安装 tunelo：network down")
    }

    func testTheLaunchFailureIsTranslated() throws {
        let binary = "cloudflared"
        let reason = "permission denied"
        XCTAssertEqual(
            try zh("couldn’t launch \(binary): \(reason)"),
            "无法启动 cloudflared：permission denied")
    }

    func testTheDidNotComeUpFailureIsTranslated() throws {
        let binary = "ngrok"
        XCTAssertEqual(
            try zh("\(binary) didn’t come up — check the network and retry"),
            "ngrok 未能启动——请检查网络后重试")
    }

    /// The one with a mixed `%@` + `%lld` key, which is the case most likely to
    /// drift: an `Int` interpolation compiles to `%lld`, not `%d`.
    func testTheRetryingFailureIsTranslated() throws {
        let binary = "tunelo"
        let delay = 48
        XCTAssertEqual(
            try zh("\(binary) keeps exiting — retrying every \(delay)s"),
            "tunelo 反复退出——每 48 秒重试一次")
    }
}
