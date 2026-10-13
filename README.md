# Throughline Wear OS

A standalone Flutter companion for Wear OS. It is designed for small, round
screens and connects directly to the same Throughline backend as the existing
Flutter phone app.

## MVP

- Sign in with the existing Throughline username and password. The bearer
  token is stored with Android secure storage.
- Use Global Chat to ask questions across previously recorded conversations.
  The thread history is loaded from and messages are sent to the shared backend.
- View open follow-up tasks from the server and mark them done.
- Capture a voice note on the watch, send it for transcription, review/edit the
  transcript, then send it to analysis.
- Type or dictate a note with the watch keyboard and submit it for analysis.
- The backend saves analyzed transcripts as conversations and extracts
  follow-up tasks.

This Wear OS app is standalone; it does not require the phone app to be
installed or connected. It needs network access for sign-in, tasks, transcription
and analysis. Captured audio is held in a temporary file and deleted after the
transcription request finishes.

## Backend API used

The routes below are from the shared Flask backend (`speech2text/app.py`):

| Method | Route | Watch use |
| --- | --- | --- |
| `POST` | `/login` | Authenticate using the existing username and password; response includes a JWT token. |
| `GET` | `/chat/global` | Load the signed-in user's persistent Global Chat thread. |
| `POST` | `/chat/global` | Send `{"prompt":"..."}` and receive a `reply` across recorded conversations. |
| `GET` | `/tasks?status=open` | Load the signed-in user's open tasks. |
| `POST` | `/tasks/{id}/complete` | Complete a task. |
| `POST` | `/transcribe` | Upload an `audio` multipart file; receive a transcript. |
| `POST` | `/analyze` | Send `{"transcript":"..."}`; backend saves a conversation and extracts tasks. |

Authenticated requests use `Authorization: Bearer <token>`, matching the phone
app's API client. The default server URL matches the existing phone app. Override
it for local development with a Dart define:

```powershell
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:5000
```

Use the backend's reachable HTTPS URL on a physical watch. For local backend
testing, the watch and development machine must be able to reach each other on
the network; `10.0.2.2` is only for an Android emulator.

## Build and install

Install Flutter and Android SDK/command-line tools, accept the Android SDK
licenses, and connect a Wear OS emulator or device:

```powershell
flutter pub get
flutter test
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`. To install
to a connected watch with USB debugging enabled:

```powershell
flutter install
```

The Android manifest declares the watch hardware feature and standalone-watch
metadata so Android identifies this as a Wear OS app.
"# throughline_wear_os" 
