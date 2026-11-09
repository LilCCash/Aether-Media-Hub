import SwiftUI
import PhotosUI
import AetherCore

// MARK: Photo

/// The photo the viewer chose as profile picture, kept on the phone (not in backups). Observed by every avatar on screen.
@MainActor
final class ProfilePhotoStore: ObservableObject {
    static let shared = ProfilePhotoStore()
    @Published private(set) var image: UIImage?

    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("avatar.jpg")
    }

    private init() { image = UIImage(contentsOfFile: url.path) }

    /// Crops the picture to a square and keeps it at most 512 points wide.
    func save(_ original: UIImage) {
        let side = min(original.size.width, original.size.height)
        guard side > 0, let cg = original.cgImage else { return }
        let scale = original.scale
        let crop = CGRect(x: (original.size.width - side) / 2 * scale, y: (original.size.height - side) / 2 * scale, width: side * scale, height: side * scale)
        guard let cropped = cg.cropping(to: crop) else { return }
        let square = UIImage(cgImage: cropped, scale: 1, orientation: original.imageOrientation)
        let target = CGSize(width: min(512, side * scale), height: min(512, side * scale))
        let resized = UIGraphicsImageRenderer(size: target).image { _ in square.draw(in: CGRect(origin: .zero, size: target)) }
        if let data = resized.jpegData(compressionQuality: 0.85) {
            try? data.write(to: url, options: .atomic)
            image = resized
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        image = nil
    }
}

extension Color {
    fileprivate init(hexRGB: String) {
        let value = UInt32(hexRGB, radix: 16) ?? 0x888888
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}

/// A round avatar: a themed one (an emoji on a gradient) or the viewer's own photo.
struct AvatarView: View {
    let avatarID: String
    var size: CGFloat = 60
    @ObservedObject private var photos = ProfilePhotoStore.shared

    var body: some View {
        ZStack {
            if avatarID == ProfileAvatars.custom, let image = photos.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                let avatar = ProfileAvatars.avatar(id: avatarID == ProfileAvatars.custom ? "popcorn" : avatarID)
                LinearGradient(colors: [Color(hexRGB: avatar.from), Color(hexRGB: avatar.to)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(avatar.emoji).font(.system(size: size * 0.52))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: max(1, size / 60)))
        .shadow(color: .black.opacity(0.25), radius: size / 12, y: size / 30)
        .accessibilityHidden(true)
    }
}

// MARK: Profile editor

/// Everything about the viewer that can be changed: name, photo, genres, invites. Opened from the pencil at the top right of the Profile.
struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var photos = ProfilePhotoStore.shared
    @State private var pickedPhoto: PhotosPickerItem?

    private var profile: ProfileSettings { return settings.value.content.profile }

    var body: some View {
        List {
            headerSection
            avatarSection
            genresSection
            invitesSection
        }
        .aetherPage()
        .navigationTitle("Modifica profilo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() }.fontWeight(.semibold) } }
        .onChange(of: pickedPhoto) { _, item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    photos.save(image)
                    settings.value.content.profile.avatar = ProfileAvatars.custom
                }
                pickedPhoto = nil
            }
        }
        .onChange(of: settings.value.content.profile.inviteNotifications) { _, _ in Task { await env.extras.refreshInvites(force: true) } }
        .onChange(of: settings.value.content.profile.invitesPerDay) { _, _ in Task { await env.extras.refreshInvites(force: true) } }
        .onChange(of: settings.value.content.profile.name) { _, _ in Task { await env.extras.refreshInvites(force: true) } }
    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 12) {
                AvatarView(avatarID: profile.avatar, size: 108)
                TextField("Il tuo nome (facoltativo)", text: settings.binding(\.content.profile.name))
                    .multilineTextAlignment(.center)
                    .font(.title2.weight(.bold))
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .accessibilityIdentifier("profile.name")
                Text("Il nome compare solo nei saluti delle notifiche. Senza nome, nessun saluto personale.")
                    .font(.caption).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }

    private var avatarSection: some View {
        Section(header: Text("Foto profilo")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 12)], spacing: 12) {
                ForEach(ProfileAvatars.all) { avatar in
                    Button { settings.value.content.profile.avatar = avatar.id } label: {
                        AvatarView(avatarID: avatar.id, size: 54)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: profile.avatar == avatar.id ? 3 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(avatar.emoji)
                    .accessibilityAddTraits(profile.avatar == avatar.id ? .isSelected : [])
                }
                if let image = photos.image {
                    Button { settings.value.content.profile.avatar = ProfileAvatars.custom } label: {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 54, height: 54).clipShape(Circle())
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: profile.avatar == ProfileAvatars.custom ? 3 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("La tua foto")
                }
            }
            .padding(.vertical, 6)
            PhotosPicker(selection: $pickedPhoto, matching: .images) { Label("Carica una foto", systemImage: "photo.badge.plus") }
                .accessibilityIdentifier("profile.photo")
            if photos.image != nil {
                Button(role: .destructive) {
                    photos.remove()
                    if profile.avatar == ProfileAvatars.custom { settings.value.content.profile.avatar = "popcorn" }
                } label: { Label("Rimuovi la mia foto", systemImage: "trash") }
            }
        }
    }

    private var genresSection: some View {
        Section(header: Text("Generi che ti piacciono"), footer: Text("Servono al gioco dei gusti e ai consigli nelle notifiche.")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                ForEach(ProfileGenre.allCases, id: \.self) { genre in
                    let on = profile.genres.contains(genre.rawValue)
                    Button { settings.value.content.profile.toggleGenre(genre) } label: {
                        HStack(spacing: 5) {
                            Text(genre.emoji)
                            Text(genre.title).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var invitesSection: some View {
        Section(header: Text("Inviti a guardare"),
                footer: Text("Qualche notifica al giorno, ognuna adatta all'ora in cui arriva, per ricordarti di guardare qualcosa: «Serata film?», un saluto con il tuo nome (solo se l'hai scritto) o un titolo che potrebbe piacerti in base ai generi scelti e ai tuoi voti. Si programmano sul telefono: apri Aether ogni tanto per tenerle aggiornate.")) {
            Toggle("Ricevi inviti", isOn: settings.binding(\.content.profile.inviteNotifications))
                .accessibilityIdentifier("profile.invites")
            if profile.inviteNotifications {
                Stepper("\(profile.invitesPerDay) al giorno", value: settings.binding(\.content.profile.invitesPerDay), in: 1...6)
            }
        }
    }
}
