# ポケット iPhone

mycmuxの作業状況と会話をiPhoneから確認するSwiftUIアプリです。利用者が用意したPocketサーバーへ、PCのQRコードまたはHTTPS URLでペアリングします。

English: A SwiftUI companion for mycmux with QR/HTTPS pairing and native conversation views. This is a source preview, not an App Store, TestFlight or signed IPA release. It requires a separately configured [Pocket server](https://github.com/miyafcos/pocket-mycmux-oss).

## 必要な環境

macOS、Xcode 26系、XcodeGen 2.44.1以上、iOS 26、Swift 6が必要です。`project.yml` がプロジェクト定義です。署名は既定で無効で、development teamは空欄です。端末配布には利用者自身のApple開発者設定が必要です。

```sh
git clone https://github.com/miyafcos/pocket-ios-oss.git
cd pocket-ios-oss
xcodegen generate --spec project.yml
xcodebuild -project PocketIOS.xcodeproj -scheme PocketIOS \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build-for-testing
```

これはシミュレーター向けアプリとテストのコンパイルです。テスト実行や実機インストールではありません。Xcodeで起動する前に接続先と通信条件を確認してください。

## 接続と安全性

作者のサーバーに接続する既定値はありません。自分で管理するPocketサーバーと認証済みのプライベートネットワークを用意し、アプリで接続先を指定します。任意のrelay設定は空入力で解除できます。ハブは選択したペアリング先を参照します。

端末への送信は作業中のセッションを変更する操作です。動作確認には人工データと通信を捕捉するURLSession stubを使ってください。DRYモードでも一部のGETは実サーバーへ届くため、DRYだけを通信隔離と考えないでください。

## 公開ソースの範囲

私用Git履歴、実会話のfixture、AppShelf、署名情報、個人向け配布スクリプトは含めません。Activityの開発用stubは人工の空JSON、skillsの実測stubは無効です。アプリのbundle/logger IDは互換性のため保持しています。

元画像の由来を確定できなかったアプリ標識3点とavatar3点は、独立した端末・ロボットの幾何画像へ置き換えました。独自symbolも盾と直剣の幾何パスに置き換えています。自作agent mark12点は生成器との全pixel一致を確認し、Pocketアイコンはプロジェクトの自作記録と照合しました。再生成の手順は [ASSET_SOURCES.md](ASSET_SOURCES.md) にあります。

## 検証

```sh
node scripts/test_read_only.mjs
```

これは通信なしのWeb読み取り専用ガード検査です。Swift/Xcode検証とは別です。同じ公開ソースで実施した検証と、実施していない項目を [VALIDATION.md](VALIDATION.md) に記録します。実機、ペアリング先との通信、XCTest実行、署名、App Store/TestFlight配信を、ビルド成功だけで確認済みとは扱いません。

## ライセンスと変更提案

自作部分は [MIT](LICENSE) です。CC Pocketの注記とMIT全文を保持しています。第三者表示は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、脆弱性の連絡は [SECURITY.md](SECURITY.md)、開発時の注意は [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。
