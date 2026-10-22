import SwiftUI
import AetherCore

// The sections of the title page that come from TMDB (with the user's own key): cast, trailers, producers, budget and revenue,
// facts and similar titles. Each one is only drawn when it has something to show.

private struct TitleSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.aetherTitle(22))
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Theme.pageMargin)
    }
}

/// The cast as a row of round photos with the name and the character underneath.
struct TitleCastSection: View {
    let people: [TitleRichDetails.Person]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TitleSectionHeader(title: "Cast")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                        VStack(spacing: 6) {
                            RemoteImage(urlString: person.photoURL, width: 160, placeholderSeed: person.name, systemPlaceholder: "person.fill")
                                .frame(width: 76, height: 76)
                                .clipShape(Circle())
                            Text(person.name)
                                .font(.caption.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            if let role = person.role {
                                Text(role)
                                    .font(.caption2)
                                    .foregroundStyle(Color.aetherSecondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                        }
                        .frame(width: 92)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(person.role.map { "\(person.name), \($0)" } ?? person.name)
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
            }
        }
        .accessibilityIdentifier("detail.cast")
    }
}

/// Every trailer TMDB lists, each opening its YouTube page.
struct TitleTrailersSection: View {
    let trailers: [TitleRichDetails.Trailer]
    @Environment(\.openURL) private var openURL

    static func subtitle(_ trailer: TitleRichDetails.Trailer) -> String {
        var parts = [trailer.type == "Teaser" ? "Teaser" : "Trailer"]
        if let code = trailer.language, !code.isEmpty { parts.append(LanguageCodes.displayName(code)) }
        if trailer.isOfficial { parts.append("Ufficiale") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TitleSectionHeader(title: "Trailer")
            VStack(spacing: 8) {
                ForEach(Array(trailers.enumerated()), id: \.offset) { index, trailer in
                    Button {
                        if let url = trailer.watchURL { openURL(url) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.rectangle.fill").font(.title3).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(trailer.name)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                Text(TitleTrailersSection.subtitle(trailer)).font(.caption).foregroundStyle(Color.aetherSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Color.aetherSecondary)
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(trailer.name), \(TitleTrailersSection.subtitle(trailer))")
                    .accessibilityHint("Apre il video su YouTube")
                    .accessibilityIdentifier("detail.trailer.\(index)")
                }
            }
            .padding(.horizontal, Theme.pageMargin)
        }
    }
}

/// Who produced it (and, for a series, which channel carries it): logos on a light tile so dark and light logos both read.
struct TitleCompaniesSection: View {
    let companies: [TitleRichDetails.Company]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TitleSectionHeader(title: "Produzione")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(companies.enumerated()), id: \.offset) { _, company in
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.92))
                                if company.logoURL != nil {
                                    RemoteImage(urlString: company.logoURL, width: 240, contentMode: .fit,
                                                placeholderSeed: company.name, systemPlaceholder: "building.2")
                                        .frame(width: 96, height: 40)
                                } else {
                                    Image(systemName: "building.2").font(.title2).foregroundStyle(Color.black.opacity(0.45))
                                }
                            }
                            .frame(width: 120, height: 64)
                            Text(company.name)
                                .font(.caption2)
                                .foregroundStyle(Color.aetherSecondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .frame(width: 120)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(company.name)
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
            }
        }
        .accessibilityIdentifier("detail.companies")
    }
}

/// What a film cost and earned. Not shown for series.
struct TitleFinancialsSection: View {
    let budget: Int?
    let revenue: Int?
    @Environment(\.dynamicTypeSize) private var typeSize

    private func tile(_ title: String, _ amount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Color.aetherSecondary)
            Text(TitleRichDetails.moneyText(amount)).font(.headline).minimumScaleFactor(0.7).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        // At the largest text sizes two half-width tiles cut the amount: they go one under the other.
        let tiles = Group {
            if let budget = budget { tile("Budget", budget) }
            if let revenue = revenue { tile("Incassi", revenue) }
        }
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 12) { tiles }
            } else {
                HStack(spacing: 12) { tiles }
            }
        }
        .padding(.horizontal, Theme.pageMargin)
        .accessibilityIdentifier("detail.financials")
    }
}

/// The facts table: status, release, length, rating, country and original language.
struct TitleFactsSection: View {
    let rows: [TitleRichDetails.Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TitleSectionHeader(title: "Dettagli")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).font(.subheadline).foregroundStyle(Color.aetherSecondary)
                        Spacer(minLength: 16)
                        Text(row.value).font(.subheadline.weight(.medium)).multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                    if index < rows.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 14)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, Theme.pageMargin)
        }
        .accessibilityIdentifier("detail.facts")
    }
}

/// Posters of similar titles; a tap opens the title like any other.
struct TitleSimilarSection: View {
    let titles: [TitleRichDetails.Similar]
    let open: (TitleRichDetails.Similar) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TitleSectionHeader(title: "Titoli simili")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { index, item in
                        Button {
                            open(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RemoteImage(urlString: item.posterURL, width: 300, placeholderSeed: item.title)
                                    .frame(width: 112, height: 168)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(item.title)
                                    .font(.caption.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                    .frame(width: 112, alignment: .leading)
                                HStack(spacing: 4) {
                                    if let year = item.year { Text(year) }
                                    if let rating = item.rating {
                                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                                        Text(String(format: "%.1f", rating))
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(Color.aetherSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.year.map { "\(item.title), \($0)" } ?? item.title)
                        .accessibilityHint("Apre la scheda del titolo")
                        .accessibilityIdentifier("detail.similar.\(index)")
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
            }
        }
        .accessibilityIdentifier("detail.similar")
    }
}

/// The credit TMDB asks for next to its data.
struct TMDBAttributionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Offerto da TMDB").font(.caption.weight(.bold))
            Text(MetadataService.tmdb.attribution).font(.caption2).foregroundStyle(Color.aetherSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail.tmdbCredit")
    }
}

/// Shown instead of the sections when no TMDB key is stored.
struct TMDBKeyHint: View {
    var body: some View {
        Label("Aggiungi la tua chiave TMDB in Impostazioni › Servizi per vedere il cast con le foto, i trailer, le produzioni, gli incassi e i titoli simili.",
              systemImage: "key")
            .font(.footnote)
            .foregroundStyle(Color.aetherSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.pageMargin)
            .accessibilityIdentifier("detail.tmdbHint")
    }
}
