import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                nowPlayingSection
                watchSection
                spotifySection
                Section {
                    Toggle("Keep running in background", isOn: $model.keepRunning)
                } footer: {
                    Text("Plays silence alongside Spotify so iOS doesn't pause WatchTune, which keeps the watch updated with the phone in your pocket.")
                }
                if let err = model.lastError {
                    Section("Last error") {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("WatchTune")
        }
    }

    private var nowPlayingSection: some View {
        Section("Now playing") {
            if let now = model.now {
                Label(now.text, systemImage: now.isPlaying ? "play.fill" : "pause.fill")
            } else {
                Text(model.signedIn ? "Nothing playing" : "Sign in to Spotify below")
                    .foregroundStyle(.secondary)
            }
            if let cmd = model.lastCommand {
                LabeledContent("Last from watch", value: cmd)
            }
        }
    }

    private var watchSection: some View {
        Section {
            LabeledContent("Status", value: model.watch.status)
            if model.watch.scanning || !model.watch.found.isEmpty {
                ForEach(model.watch.found) { f in
                    Button { model.watch.choose(f.peripheral) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(f.name)
                                if f.hasForge {
                                    Text("Forge watch").font(.caption).foregroundStyle(.green)
                                } else if f.alreadyConnected {
                                    Text("Connected to this phone").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if !f.alreadyConnected {
                                Text("\(f.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Button(model.watch.scanning ? "Searching…" : "Find watch") { model.watch.startScan() }
                .disabled(model.watch.scanning)
            if model.watch.hasSavedWatch {
                Button("Forget watch", role: .destructive) { model.watch.forget() }
            }
        } header: {
            Text("Watch")
        } footer: {
            Text("Put the WatchTune face on your Ollee Watch first. If your watch isn't listed, tap Find watch with the Ollee app closed.")
        }
    }

    private var spotifySection: some View {
        Section {
            TextField("Spotify Client ID", text: $model.clientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
            if model.signedIn {
                Button("Sign out of Spotify", role: .destructive) { model.signOut() }
            } else {
                Button("Sign in to Spotify") { Task { await model.signIn() } }
                    .disabled(model.clientID.isEmpty)
            }
        } header: {
            Text("Spotify")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("In the Spotify developer dashboard, add this Redirect URI to your app:")
                Text(Spotify.redirectURI).textSelection(.enabled).font(.system(.footnote, design: .monospaced))
            }
        }
    }
}
