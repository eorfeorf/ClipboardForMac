# Clipboard for Mac

Windows の `Win + V` に近いクリップボード履歴を macOS のメニューバーに追加するアプリです。

macOS 14 以降の Apple Silicon と Intel の Mac に対応します。ライセンスは [MIT](LICENSE) です。

## 別のMacで使う

1. [Releases](https://github.com/eorfeorf/ClipboardForMac/releases) から `ClipboardForMac-v1.0.0-macOS-universal.zip` をダウンロードして展開します。
2. `ClipboardForMac.app` を「アプリケーション」フォルダーへ移動して開きます。
3. macOS が保存先フォルダーへのアクセスを求めたら許可します。自動貼り付けを使う場合は、アプリ内の案内から「アクセシビリティ」も許可します。

配布版は Apple による公証を受けていません。初回起動がブロックされた場合は、[Apple の案内](https://support.apple.com/ja-jp/102445)に沿って「システム設定」→「プライバシーとセキュリティ」から開いてください。履歴は各 Mac に保存されます。

## 使い方

1. テキスト、書式付きテキスト、画像、ファイルをコピーします。
2. `⌥V` またはメニューバーのクリップボードアイコンで履歴を開きます。
3. 項目をクリックするか、矢印キーで選んで Return キーを押します。

`⌥⇧S` で撮影範囲を選べます。撮影した画像はクリップボードに入り、履歴にも追加されます。Esc キーでキャンセルできます。

通常のスクリーンショットは、macOS の保存先フォルダーに新しい画像ファイルが保存されると履歴にも追加されます。クリップボードの内容は変更しません。アプリの起動前からある画像や、スクリーンショット以外の画像ファイルは取り込みません。macOS から保存先フォルダーへのアクセスを求められた場合は許可してください。スクリーンショットの保存先が「クリップボード」の場合は、通常のコピー画像として記録します。

項目はクリップボードに戻されます。「アクセシビリティ」を許可すると、直前のアプリへ自動で貼り付けます。許可しない場合は、元のアプリで `⌘V` を押してください。許可は履歴画面の「自動貼り付けを許可」から設定できます。

検索、固定、個別削除、未固定履歴の一括消去に対応します。最大 25 件の未固定履歴を保持し、固定した項目は件数に含みません。履歴はこの Mac の `~/Library/Application Support/ClipboardForMac/` に保存されます。パスワード管理アプリなどが「秘匿」または「一時」の貼り付けデータとして指定した内容は記録しません。

履歴画面右下のメニューで「ログイン時に起動」を選べます。この設定は「アプリケーション」フォルダーに配置してから行ってください。

## 開発

Swift Package Manager と Xcode 16 でビルドできます。別の Mac でソースからビルドする場合は以下を実行してください。

```sh
git clone https://github.com/eorfeorf/ClipboardForMac.git
cd ClipboardForMac
swift build
swift test
./scripts/build-app.sh
```

`dist/ClipboardForMac.app` を「アプリケーション」フォルダーへ移動して開きます。Apple Silicon と Intel の両方に対応する配布用 ZIP は `./scripts/package-release.sh` で作成できます。
