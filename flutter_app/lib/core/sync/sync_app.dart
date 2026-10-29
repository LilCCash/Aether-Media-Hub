/// The application keys of Aether itself at Trakt and Simkl, so the viewer signs in with a normal account (the code or PIN is shown, the
/// service's page is opened) and never sees a developer page. They are public identifiers of the app, not of the viewer. Build with
/// `--dart-define=TRAKT_CLIENT_ID=… --dart-define=TRAKT_CLIENT_SECRET=… --dart-define=SIMKL_CLIENT_ID=…` or put them below.
/// While they are empty the settings still ask for the viewer's own keys (the older, advanced way).
class SyncApp {
  static const traktClientId = String.fromEnvironment(
    'TRAKT_CLIENT_ID',
    defaultValue: '',
  );
  static const traktClientSecret = String.fromEnvironment(
    'TRAKT_CLIENT_SECRET',
    defaultValue: '',
  );
  static const simklClientId = String.fromEnvironment(
    'SIMKL_CLIENT_ID',
    defaultValue: '',
  );

  static bool get hasTrakt =>
      traktClientId.isNotEmpty && traktClientSecret.isNotEmpty;
  static bool get hasSimkl => simklClientId.isNotEmpty;
}
