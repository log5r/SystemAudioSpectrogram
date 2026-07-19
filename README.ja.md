# System Audio Spectrogram

[English](README.md) | [日本語](README.ja.md)

System Audio Spectrogramは、Macのシステム出力音声をキャプチャし、スクロールするステレオスペクトログラムをリアルタイムで描画するmacOSネイティブアプリです。周波数解析に特化したインターフェイスに、左右チャンネルの個別表示とシンプルなレベル表示を備えています。

![ステレオのサンプルスペクトログラムを表示するSystem Audio Spectrogram](docs/system-audio-spectrogram.png)

## 機能

- Core Audioのプロセスタップによるステレオのシステム出力キャプチャ
- AppKit／Core Animationによる安定した連続スクロール表示
- 8、12、16、20、24 kHzから選択できる周波数範囲
- リニアおよび対数周波数スケール
- 低速、標準、高速の履歴表示速度
- 標準、高、最高のFFT／表示解像度プリセット
- キャプチャの開始／停止と、左右チャンネルのコンパクトなdB表示
- 現在のステレオスペクトログラムをワンクリックでPNG保存
- 連続保存に使える、次回起動後も保持される出力先フォルダ設定
- 音声録音やネットワーク通信を行わないローカル処理

## 動作要件

- macOS 14.2以降
- Xcode 26.5以降（Xcode 26.6で動作確認済み）

## ビルド

Xcodeで`SystemAudioSpectrogram.xcodeproj`を開き、`SystemAudioSpectrogram`スキームを実行します。または、ターミナルからコード署名なしでビルドします。

```bash
xcodebuild \
  -project SystemAudioSpectrogram.xcodeproj \
  -scheme SystemAudioSpectrogram \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

ユニットテストは次のコマンドで実行できます。

```bash
xcodebuild \
  -project SystemAudioSpectrogram.xcodeproj \
  -scheme SystemAudioSpectrogram \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:SystemAudioSpectrogramTests \
  test
```

このプロジェクトでは、Apple Developerのチームを固定していません。署名付きのローカルビルドが必要な場合は、Xcodeでご自身のチームを選択してください。

## システムオーディオのアクセス許可

初めてキャプチャを開始すると、macOSがアクセス許可を求めます。キャプチャを拒否した場合は、「システム設定」の「プライバシーとセキュリティ」でこのアプリを許可し、キャプチャを停止してから再度開始してください。

このアプリはサンドボックス化されています。Core Audioのキャプチャ処理に必要なオーディオ入力権限に加え、ユーザーが明示的に選択した画像出力フォルダにのみアクセスします。

## プライバシー

音声はMac上でローカルに解析されます。キャプチャした音声を録音、保存、送信することはありません。「Save Image」を押した場合に限り、表示中のスペクトログラムを描画したPNG画像を書き出します。

このプロジェクトには、ネットワーククライアント、音声ファイルへの書き込み処理、キャプチャしたサンプルを永続化する処理は含まれていません。音声フレームはメモリ上で音量レベルとFFTビンに変換され、可視化後に破棄されます。

## 既知の制限事項

- キャプチャの対象は共有システム出力です。現在、個別のプロセスを選択する機能はありません。
- 保護された音声経路やデバイス固有の音声経路では、プロセスタップを利用できない場合があります。
- 最初の公開ビルドでは、対象のmacOSリリース上で5分以上の手動動作確認を行い、タップおよび集約デバイスが正常に破棄されることを確認する必要があります。

## ライセンス

MIT Licenseのもとで公開しています。詳細は[LICENSE](LICENSE)をご覧ください。
