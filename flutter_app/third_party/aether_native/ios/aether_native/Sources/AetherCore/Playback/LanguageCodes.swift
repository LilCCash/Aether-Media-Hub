import Foundation

// Language handling for subtitles, audio tracks and stream metadata.
//
// Sources of language values seen in the wild (docs/05-SUBTITLES-RESEARCH.md §2.5, docs/research/api-probe-2026-10-20.md):
//  * ISO 639-2/B and 639-2/T mixed in the same addon response (`fre` and `fra`, `cze` and `ces`, `ell`, `ron`...);
//  * OpenSubtitles inventions: `pob` (Brazilian Portuguese), `zht` (Traditional Chinese), `zhe` (bilingual Chinese);
//  * Stremio Web label codes: `spl` (Latin American Spanish);
//  * ISO 639-1 and BCP-47 tags from system locales and AVFoundation (`it`, `pt-BR`, `zh-Hans-CN`);
//  * free text when the addon does not send a valid code (`English`, `Português Brazil`) - the Stremio SDK says the text is displayed.

/// One row per language: `alpha2|alpha3 bibliographic|alpha3 terminologic|Italian name|English name|native names (comma separated)`.
/// An empty alpha3 bibliographic column means "same as terminologic". An empty alpha2 column means the language has no
/// ISO 639-1 code (its stable code is then the three letter one). 639-3 codes of languages that have a 639-1 code equal the
/// terminologic code, so they are covered by the same rows.
private let languageTableText: String = """
aa||aar|Afar|Afar|
ab||abk|Abcaso|Abkhazian|
ae||ave|Avestico|Avestan|
af||afr|Afrikaans|Afrikaans|
ak||aka|Akan|Akan|
am||amh|Amarico|Amharic|አማርኛ
an||arg|Aragonese|Aragonese|
ar||ara|Arabo|Arabic|العربية
as||asm|Assamese|Assamese|
av||ava|Avaro|Avaric|
ay||aym|Aymara|Aymara|
az||aze|Azero|Azerbaijani|azərbaycan,azərbaycanca
ba||bak|Baschiro|Bashkir|
be||bel|Bielorusso|Belarusian|беларуская
bg||bul|Bulgaro|Bulgarian|български
bi||bis|Bislama|Bislama|
bm||bam|Bambara|Bambara|
bn||ben|Bengalese|Bengali|বাংলা
bo|tib|bod|Tibetano|Tibetan|
br||bre|Bretone|Breton|brezhoneg
bs||bos|Bosniaco|Bosnian|bosanski
ca||cat|Catalano|Catalan|català
ce||che|Ceceno|Chechen|
ch||cha|Chamorro|Chamorro|
co||cos|Corso|Corsican|corsu
cr||cre|Cree|Cree|
cs|cze|ces|Ceco|Czech|čeština,cesky
cu||chu|Slavo ecclesiastico|Church Slavic|
cv||chv|Ciuvascio|Chuvash|
cy|wel|cym|Gallese|Welsh|cymraeg
da||dan|Danese|Danish|dansk
de|ger|deu|Tedesco|German|deutsch
dv||div|Divehi|Divehi|
dz||dzo|Dzongkha|Dzongkha|
ee||ewe|Ewe|Ewe|
el|gre|ell|Greco|Greek|ελληνικά
en||eng|Inglese|English|
eo||epo|Esperanto|Esperanto|
es||spa|Spagnolo|Spanish|español,castellano
et||est|Estone|Estonian|eesti
eu|baq|eus|Basco|Basque|euskara
fa|per|fas|Persiano|Persian|فارسی
ff||ful|Fula|Fulah|
fi||fin|Finlandese|Finnish|suomi
fj||fij|Figiano|Fijian|
fo||fao|Faroese|Faroese|føroyskt
fr|fre|fra|Francese|French|français
fy||fry|Frisone occidentale|Western Frisian|frysk
ga||gle|Irlandese|Irish|gaeilge
gd||gla|Gaelico scozzese|Scottish Gaelic|
gl||glg|Galiziano|Galician|galego
gn||grn|Guaranì|Guarani|
gu||guj|Gujarati|Gujarati|
gv||glv|Mannese|Manx|
ha||hau|Hausa|Hausa|
he||heb|Ebraico|Hebrew|עברית
hi||hin|Hindi|Hindi|हिन्दी
ho||hmo|Hiri Motu|Hiri Motu|
hr||hrv|Croato|Croatian|hrvatski
ht||hat|Creolo haitiano|Haitian|
hu||hun|Ungherese|Hungarian|magyar
hy|arm|hye|Armeno|Armenian|հայերեն
hz||her|Herero|Herero|
ia||ina|Interlingua|Interlingua|
id||ind|Indonesiano|Indonesian|bahasa indonesia
ie||ile|Interlingue|Interlingue|
ig||ibo|Igbo|Igbo|
ii||iii|Yi del Sichuan|Sichuan Yi|
ik||ipk|Inupiak|Inupiaq|
io||ido|Ido|Ido|
is|ice|isl|Islandese|Icelandic|íslenska
it||ita|Italiano|Italian|
iu||iku|Inuktitut|Inuktitut|
ja||jpn|Giapponese|Japanese|日本語
jv||jav|Giavanese|Javanese|
ka|geo|kat|Georgiano|Georgian|ქართული
kg||kon|Kongo|Kongo|
ki||kik|Kikuyu|Kikuyu|
kj||kua|Kuanyama|Kuanyama|
kk||kaz|Kazako|Kazakh|қазақ
kl||kal|Groenlandese|Kalaallisut|
km||khm|Khmer|Khmer|ខ្មែរ
kn||kan|Kannada|Kannada|ಕನ್ನಡ
ko||kor|Coreano|Korean|한국어
kr||kau|Kanuri|Kanuri|
ks||kas|Kashmiri|Kashmiri|
ku||kur|Curdo|Kurdish|kurdî
kv||kom|Komi|Komi|
kw||cor|Cornico|Cornish|
ky||kir|Kirghiso|Kyrgyz|кыргызча
la||lat|Latino|Latin|latina
lb||ltz|Lussemburghese|Luxembourgish|lëtzebuergesch
lg||lug|Ganda|Ganda|
li||lim|Limburghese|Limburgish|
ln||lin|Lingala|Lingala|
lo||lao|Lao|Lao|ລາວ
lt||lit|Lituano|Lithuanian|lietuvių
lu||lub|Luba-Katanga|Luba-Katanga|
lv||lav|Lettone|Latvian|latviešu
mg||mlg|Malgascio|Malagasy|
mh||mah|Marshallese|Marshallese|
mi|mao|mri|Maori|Maori|
mk|mac|mkd|Macedone|Macedonian|македонски
ml||mal|Malayalam|Malayalam|മലയാളം
mn||mon|Mongolo|Mongolian|монгол
mr||mar|Marathi|Marathi|मराठी
ms|may|msa|Malese|Malay|bahasa melayu
mt||mlt|Maltese|Maltese|malti
my|bur|mya|Birmano|Burmese|မြန်မာ
na||nau|Nauruano|Nauru|
nb||nob|Norvegese bokmål|Norwegian Bokmål|norsk bokmål
nd||nde|Ndebele settentrionale|North Ndebele|
ne||nep|Nepalese|Nepali|नेपाली
ng||ndo|Ndonga|Ndonga|
nl|dut|nld|Olandese|Dutch|nederlands,vlaams
nn||nno|Norvegese nynorsk|Norwegian Nynorsk|nynorsk
no||nor|Norvegese|Norwegian|norsk
nr||nbl|Ndebele meridionale|South Ndebele|
nv||nav|Navajo|Navajo|
ny||nya|Chichewa|Chichewa|
oc||oci|Occitano|Occitan|occitan
oj||oji|Ojibwa|Ojibwa|
om||orm|Oromo|Oromo|
or||ori|Odia|Oriya|
os||oss|Osseto|Ossetian|
pa||pan|Punjabi|Punjabi|ਪੰਜਾਬੀ
pi||pli|Pali|Pali|
pl||pol|Polacco|Polish|polski
ps||pus|Pashto|Pashto|پښتو
pt||por|Portoghese|Portuguese|português
qu||que|Quechua|Quechua|
rm||roh|Romancio|Romansh|
rn||run|Kirundi|Rundi|
ro|rum|ron|Rumeno|Romanian|română
ru||rus|Russo|Russian|русский
rw||kin|Kinyarwanda|Kinyarwanda|
sa||san|Sanscrito|Sanskrit|
sc||srd|Sardo|Sardinian|
sd||snd|Sindhi|Sindhi|
se||sme|Sami settentrionale|Northern Sami|
sg||sag|Sango|Sango|
si||sin|Singalese|Sinhala|සිංහල
sk|slo|slk|Slovacco|Slovak|slovenčina
sl||slv|Sloveno|Slovenian|slovenščina
sm||smo|Samoano|Samoan|
sn||sna|Shona|Shona|
so||som|Somalo|Somali|
sq|alb|sqi|Albanese|Albanian|shqip
sr||srp|Serbo|Serbian|српски,srpski
ss||ssw|Swati|Swati|
st||sot|Sotho meridionale|Southern Sotho|
su||sun|Sundanese|Sundanese|
sv||swe|Svedese|Swedish|svenska
sw||swa|Swahili|Swahili|kiswahili
ta||tam|Tamil|Tamil|தமிழ்
te||tel|Telugu|Telugu|తెలుగు
tg||tgk|Tagico|Tajik|тоҷикӣ
th||tha|Thailandese|Thai|ไทย
ti||tir|Tigrino|Tigrinya|
tk||tuk|Turkmeno|Turkmen|
tl||tgl|Tagalog|Tagalog|
tn||tsn|Tswana|Tswana|
to||ton|Tongano|Tonga|
tr||tur|Turco|Turkish|türkçe
ts||tso|Tsonga|Tsonga|
tt||tat|Tataro|Tatar|
tw||twi|Twi|Twi|
ty||tah|Tahitiano|Tahitian|
ug||uig|Uiguro|Uyghur|
uk||ukr|Ucraino|Ukrainian|українська
ur||urd|Urdu|Urdu|اردو
uz||uzb|Uzbeco|Uzbek|o'zbek
ve||ven|Venda|Venda|
vi||vie|Vietnamita|Vietnamese|tiếng việt
vo||vol|Volapük|Volapük|
wa||wln|Vallone|Walloon|
wo||wol|Wolof|Wolof|
xh||xho|Xhosa|Xhosa|
yi||yid|Yiddish|Yiddish|ייִדיש
yo||yor|Yoruba|Yoruba|
za||zha|Zhuang|Zhuang|
zh|chi|zho|Cinese|Chinese|中文,汉语,漢語
zu||zul|Zulu|Zulu|
||ast|Asturiano|Asturian|asturianu
||ceb|Cebuano|Cebuano|
||cnr|Montenegrino|Montenegrin|crnogorski
||fil|Filippino|Filipino|filipino
||gsw|Svizzero tedesco|Swiss German|schwiizerdütsch
||haw|Hawaiano|Hawaiian|
||hmn|Hmong|Hmong|
||tlh|Klingon|Klingon|
||yue|Cantonese|Cantonese|粵語,廣東話
||und|Lingua non specificata|Undetermined|
||mul|Più lingue|Multiple languages|
||zxx|Nessun contenuto linguistico|No linguistic content|
"""

/// Parsed form of one table row.
private struct LanguageEntry {
    let alpha2: String
    let alpha3B: String
    let alpha3T: String
    let italian: String
    let english: String
    let natives: [String]

    /// Stable code of the language: ISO 639-1 when it exists, the three letter code otherwise.
    var base: String {
        return alpha2.isEmpty ? alpha3T : alpha2
    }
}

/// Lowercased, diacritics removed: the key used for every lookup, so "Português", "portugues" and "PORTUGUÊS" are the same.
private func foldLanguageKey(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.lowercased().folding(options: .diacriticInsensitive, locale: nil)
}

/// Lookup tables built once from `languageTableText`.
private struct LanguageIndex {
    /// Any code (639-1, 639-2/B, 639-2/T, 639-3, deprecated) to the stable base code.
    var codeToBase: [String: String] = [:]
    /// Folded English, Italian and native names to the stable base code.
    var nameToBase: [String: String] = [:]
    /// Stable base code to the Italian display name.
    var italianNames: [String: String] = [:]

    /// Deprecated ISO 639-1/639-2 codes and 639-3 individual languages that belong to a macrolanguage with a 639-1 code.
    private static let extraCodes: [String: String] = [
        "iw": "he", "in": "id", "ji": "yi", "jw": "jv", "mo": "ro", "scc": "sr", "scr": "hr",
        "cmn": "zh", "arb": "ar", "pes": "fa", "prs": "fa", "zsm": "ms", "zlm": "ms", "ekk": "et",
        "lvs": "lv", "swh": "sw", "uzn": "uz", "uzs": "uz", "azj": "az", "azb": "az", "khk": "mn",
        "mvf": "mn", "plt": "mg", "xmv": "mg", "quz": "qu", "ydd": "yi", "als": "sq", "gug": "gn"
    ]

    init(table: String) {
        let lines = table.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            let fields: [String] = line.split(separator: "|", omittingEmptySubsequences: false).map { String($0) }
            if fields.count < 5 { continue }
            var natives: [String] = []
            if fields.count > 5 {
                natives = fields[5].split(separator: ",", omittingEmptySubsequences: true).map { String($0) }
            }
            let entry = LanguageEntry(alpha2: fields[0], alpha3B: fields[1], alpha3T: fields[2],
                                      italian: fields[3], english: fields[4], natives: natives)
            register(entry)
        }
        for (code, base) in LanguageIndex.extraCodes {
            addCode(code, base: base)
        }
    }

    private mutating func register(_ entry: LanguageEntry) {
        let base = entry.base
        addCode(entry.alpha2, base: base)
        addCode(entry.alpha3B, base: base)
        addCode(entry.alpha3T, base: base)
        addName(entry.english, base: base)
        addName(entry.italian, base: base)
        for native in entry.natives {
            addName(native, base: base)
        }
        italianNames[base] = entry.italian
    }

    private mutating func addCode(_ code: String, base: String) {
        let key = code.lowercased()
        if key.isEmpty { return }
        if codeToBase[key] == nil { codeToBase[key] = base }
    }

    private mutating func addName(_ name: String, base: String) {
        let key = foldLanguageKey(name)
        if key.isEmpty { return }
        if nameToBase[key] == nil { nameToBase[key] = base }
    }
}

/// A recognised language: `code` is the stable code (may carry a variant, e.g. `pt-BR`), `base` is the language alone (`pt`).
struct ResolvedLanguage: Equatable {
    var code: String
    var base: String

    var hasVariant: Bool { return code != base }
}

/// Maps ISO 639-1 / 639-2 (B and T) / 639-3 codes, BCP-47 tags, OpenSubtitles aliases and common language names to one stable code,
/// so subtitles, audio tracks and user preferences can be compared.
///
/// Stable code: the ISO 639-1 code when the language has one (`it`, `en`), the three letter code otherwise (`fil`, `yue`),
/// plus a variant only where the variant changes what the viewer reads: `pt-BR`, `pt-PT`, `zh-Hans`, `zh-Hant`, `es-419`.
/// Regions that do not matter for subtitles are dropped (`en-US` becomes `en`). Text that is not recognised is kept as it is
/// (trimmed and lowercased by `normalise`, untouched by `displayName`), which is what the Stremio SDK does with an invalid `lang`.
public enum LanguageCodes {
    private static let index = LanguageIndex(table: languageTableText)

    /// Codes and names that do not follow the generic rules. Keys are folded (see `foldLanguageKey`).
    private static let aliasCodes: [String: String] = [
        // OpenSubtitles / Stremio inventions.
        "pob": "pt-BR", "zht": "zh-Hant", "zhe": "zh", "spl": "es-419",
        // Region spellings that are not BCP-47 shaped.
        "brazilian": "pt-BR", "brazilian portuguese": "pt-BR", "portuguese (brazil)": "pt-BR",
        "portuguese (brazilian)": "pt-BR", "portugues brasil": "pt-BR", "portugues brazil": "pt-BR",
        "portugues (brasil)": "pt-BR", "portugues do brasil": "pt-BR", "portoghese (brasile)": "pt-BR",
        "portoghese brasiliano": "pt-BR",
        "european portuguese": "pt-PT", "portuguese (portugal)": "pt-PT", "portugues (portugal)": "pt-PT",
        "portoghese (portogallo)": "pt-PT", "portoghese europeo": "pt-PT",
        "traditional chinese": "zh-Hant", "chinese traditional": "zh-Hant", "chinese (traditional)": "zh-Hant",
        "cinese tradizionale": "zh-Hant",
        "simplified chinese": "zh-Hans", "chinese simplified": "zh-Hans", "chinese (simplified)": "zh-Hans",
        "cinese semplificato": "zh-Hans",
        "chinese bilingual": "zh", "cinese (bilingue)": "zh",
        "latin american spanish": "es-419", "spanish (latin america)": "es-419", "espanol (america latina)": "es-419",
        "spagnolo (america latina)": "es-419", "espanol latino": "es-419"
    ]

    /// Display names that differ from the generic name of the stable code.
    private static let aliasDisplayNames: [String: String] = [
        "zhe": "Cinese (bilingue)",
        "chinese bilingual": "Cinese (bilingue)"
    ]

    /// Italian names of the variant codes.
    private static let variantNames: [String: String] = [
        "pt-BR": "Portoghese (Brasile)",
        "pt-PT": "Portoghese (Portogallo)",
        "zh-Hans": "Cinese semplificato",
        "zh-Hant": "Cinese tradizionale",
        "es-419": "Spagnolo (America Latina)"
    ]

    // MARK: Resolution

    /// Recognises `raw`, or returns nil for empty or unknown text.
    static func resolve(_ raw: String) -> ResolvedLanguage? {
        let key = foldLanguageKey(raw)
        if key.isEmpty { return nil }
        if let aliasCode = aliasCodes[key] {
            return makeResolved(code: aliasCode)
        }
        if let base = index.codeToBase[key] {
            return ResolvedLanguage(code: base, base: base)
        }
        if let tagged = resolveTag(key) {
            return tagged
        }
        if let base = index.nameToBase[key] {
            return ResolvedLanguage(code: base, base: base)
        }
        return nil
    }

    private static func makeResolved(code: String) -> ResolvedLanguage {
        if let dash = code.firstIndex(of: "-") {
            return ResolvedLanguage(code: code, base: String(code[code.startIndex..<dash]))
        }
        return ResolvedLanguage(code: code, base: code)
    }

    /// BCP-47 style tags (`pt-BR`, `pt_br`, `zh-Hans-CN`, `eng-US`): language subtag first, then optional script and region.
    private static func resolveTag(_ key: String) -> ResolvedLanguage? {
        let subtags: [String] = key.split(whereSeparator: { (character: Character) -> Bool in
            return character == "-" || character == "_"
        }).map { String($0) }
        guard subtags.count >= 2, let base = index.codeToBase[subtags[0]] else { return nil }
        var script: String?
        var region: String?
        for tag in subtags.dropFirst() {
            let allLetters = tag.allSatisfy { $0.isLetter }
            let allDigits = tag.allSatisfy { $0.isNumber }
            if tag.count == 4 && allLetters {
                if script == nil { script = tag }
            } else if (tag.count == 2 && allLetters) || (tag.count == 3 && allDigits) {
                if region == nil { region = tag }
            }
        }
        let code = variantCode(base: base, script: script, region: region)
        return ResolvedLanguage(code: code, base: base)
    }

    private static func variantCode(base: String, script: String?, region: String?) -> String {
        switch base {
        case "pt":
            if region == "br" { return "pt-BR" }
            if region == "pt" { return "pt-PT" }
            return base
        case "zh":
            if script == "hans" { return "zh-Hans" }
            if script == "hant" { return "zh-Hant" }
            if region == "cn" || region == "sg" || region == "my" { return "zh-Hans" }
            if region == "tw" || region == "hk" || region == "mo" { return "zh-Hant" }
            return base
        case "es":
            if region == "419" || region == "la" { return "es-419" }
            return base
        default:
            return base
        }
    }

    /// Norwegian written standards are interchangeable for a viewer looking for subtitles.
    private static func family(_ base: String) -> String {
        if base == "nb" || base == "nn" { return "no" }
        return base
    }

    // MARK: Public API

    /// Stable code for any spelling of a language (see the type documentation). Unknown text is returned trimmed and lowercased.
    public static func normalise(_ raw: String) -> String {
        if let resolved = resolve(raw) { return resolved.code }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The language without its variant: `pt-BR` gives `pt`, `zh-Hant` gives `zh`. Use it to compare with data that only
    /// carries two letter codes (for example `StreamInfo.languages`). Unknown text is returned trimmed and lowercased.
    public static func baseLanguage(_ raw: String) -> String {
        if let resolved = resolve(raw) { return resolved.base }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Language name for the UI. Italian by default; unknown text is returned as it was received (trimmed).
    public static func displayName(_ raw: String, locale: Locale = Locale(identifier: "it_IT")) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Lingua non specificata" }
        let key = foldLanguageKey(trimmed)
        if let special = aliasDisplayNames[key] { return special }
        guard let resolved = resolve(trimmed) else { return trimmed }
        if let localised = localisedName(for: resolved, locale: locale) { return localised }
        return trimmed
    }

    /// True when both values denote the same language. A value without variant matches every variant of its language
    /// (`pt` matches `pt-BR` and `pob`), two different variants do not (`pt-BR` does not match `pt-PT`).
    /// Empty text never matches; unknown text only matches identical text (case-insensitive).
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        return matchStrength(lhs, rhs) > 0
    }

    /// 2 = same stable code, 1 = same language with a variant on at most one side (or Norwegian standards), 0 = different.
    static func matchStrength(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty || right.isEmpty { return 0 }
        guard let first = resolve(left), let second = resolve(right) else {
            return left.lowercased() == right.lowercased() ? 2 : 0
        }
        if first.code == second.code { return 2 }
        if family(first.base) != family(second.base) { return 0 }
        if first.hasVariant && second.hasVariant { return 0 }
        return 1
    }

    // MARK: Names

    private static func localisedName(for resolved: ResolvedLanguage, locale: Locale) -> String? {
        let italian: String? = variantNames[resolved.code] ?? index.italianNames[resolved.base]
        if isItalian(locale) { return italian }
        var system: String?
        if resolved.hasVariant {
            system = locale.localizedString(forIdentifier: resolved.code)
        } else {
            system = locale.localizedString(forLanguageCode: resolved.base)
        }
        if let text = system, !text.isEmpty {
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        return italian
    }

    private static func isItalian(_ locale: Locale) -> Bool {
        let identifier = locale.identifier.lowercased()
        return identifier == "it" || identifier.hasPrefix("it_") || identifier.hasPrefix("it-")
    }
}
