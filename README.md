# mac_andro

Flutter port of the Kivy dashboard in
`/Users/apurvchaudhary/Documents/github/macandro_gauge`.

## Features

- Four animated radial gauges for `CPU`, `Memory`, `Network`, and `Battery`
- Dual clocks for `New Delhi` and `Munich`
- Swipeable month calendar with a full-screen day picker
- Scrollable daily schedule timeline with overlapping event layout
- Live events panel that highlights the next upcoming event
- Polling against the same local API used by the Kivy app

## API

The app reads from:

- `http://192.168.1.30:8001/stats`
- `http://192.168.1.30:8001/events?date=YYYY-MM-DD`

Android, iOS, and macOS project settings were updated to allow this local
cleartext HTTP traffic.

## Run

```bash
flutter pub get
flutter run
```

## Verify

```bash
flutter analyze
flutter test
```

## Build Android

```bash
flutter build apk --debug
```
