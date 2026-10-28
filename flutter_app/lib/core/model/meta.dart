import '../util/lenient.dart';

/// An item of a catalog or the full details of a title (Stremio "meta").
class Video {
  const Video({required this.id, required this.title, this.season, this.episode, this.released, this.thumbnail, this.overview});

  final String id;
  final String title;
  final int? season;
  final int? episode;
  final DateTime? released;
  final String? thumbnail;
  final String? overview;

  bool get isEpisode => season != null && episode != null;

  String get label => isEpisode ? 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}' : title;

  static Video? parse(Object? raw) {
    final map = asMap(raw);
    final id = asNonEmptyString(map?['id']);
    if (map == null || id == null) return null;
    return Video(
      id: id,
      title: asNonEmptyString(map['title']) ?? asNonEmptyString(map['name']) ?? id,
      season: asInt(map['season']),
      episode: asInt(map['episode']) ?? asInt(map['number']),
      released: asDate(map['released']),
      thumbnail: asNonEmptyString(map['thumbnail']),
      overview: asNonEmptyString(map['overview']) ?? asNonEmptyString(map['description']),
    );
  }
}

class MetaItem {
  const MetaItem({
    required this.id,
    required this.type,
    required this.name,
    this.poster,
    this.background,
    this.logo,
    this.description,
    this.releaseInfo,
    this.imdbRating,
    this.runtime,
    this.genres = const [],
    this.cast = const [],
    this.directors = const [],
    this.videos = const [],
    this.trailerYoutubeIds = const [],
    this.landscape = false,
  });

  final String id;
  final String type;
  final String name;
  final String? poster;
  final String? background;
  final String? logo;
  final String? description;
  final String? releaseInfo;
  final String? imdbRating;
  final String? runtime;
  final List<String> genres;
  final List<String> cast;
  final List<String> directors;
  final List<Video> videos;
  final List<String> trailerYoutubeIds;

  /// The addon asks for 16:9 artwork (`posterShape: landscape`).
  final bool landscape;

  bool get isSeries => videos.any((v) => v.isEpisode);

  List<int> get seasons {
    final set = videos.where((v) => v.season != null).map((v) => v.season!).toSet().toList()..sort();
    return set;
  }

  List<Video> episodesOf(int season) =>
      videos.where((v) => v.season == season).toList()..sort((a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0));

  static MetaItem? parse(Object? raw, {String? fallbackType}) {
    final map = asMap(raw);
    final id = asNonEmptyString(map?['id']);
    if (map == null || id == null) return null;
    final videos = <Video>[];
    for (final item in asList(map['videos'])) {
      final v = Video.parse(item);
      if (v != null) videos.add(v);
    }
    final trailers = <String>[];
    for (final item in asList(map['trailers'])) {
      final source = asNonEmptyString(asMap(item)?['source']);
      if (source != null) trailers.add(source);
    }
    return MetaItem(
      id: id,
      type: asNonEmptyString(map['type']) ?? fallbackType ?? 'movie',
      name: asNonEmptyString(map['name']) ?? id,
      poster: asNonEmptyString(map['poster']),
      background: asNonEmptyString(map['background']) ?? asNonEmptyString(map['fanart']),
      logo: asNonEmptyString(map['logo']),
      description: asNonEmptyString(map['description']),
      releaseInfo: asNonEmptyString(map['releaseInfo']) ?? asNonEmptyString(map['year']),
      imdbRating: asNonEmptyString(map['imdbRating']),
      runtime: asNonEmptyString(map['runtime']),
      genres: asStringList(map['genres']).isNotEmpty ? asStringList(map['genres']) : asStringList(map['genre']),
      cast: asStringList(map['cast']),
      directors: asStringList(map['director']).isNotEmpty ? asStringList(map['director']) : asStringList(map['directors']),
      videos: videos,
      trailerYoutubeIds: trailers,
      landscape: asNonEmptyString(map['posterShape']) == 'landscape',
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type,
        'name': name,
        if (poster != null) 'poster': poster,
        if (background != null) 'background': background,
        if (logo != null) 'logo': logo,
        if (description != null) 'description': description,
        if (releaseInfo != null) 'releaseInfo': releaseInfo,
        if (imdbRating != null) 'imdbRating': imdbRating,
        if (runtime != null) 'runtime': runtime,
        'genres': genres,
        'cast': cast,
        'director': directors,
        if (landscape) 'posterShape': 'landscape',
      };

  /// A light copy for catalogs / lists (no videos), as kept by the library.
  MetaItem get preview => MetaItem(id: id, type: type, name: name, poster: poster, background: background, releaseInfo: releaseInfo, landscape: landscape);

  MetaItem mergedWith(MetaItem? detail) {
    if (detail == null) return this;
    return MetaItem(
      id: detail.id,
      type: detail.type,
      name: detail.name,
      poster: detail.poster ?? poster,
      background: detail.background ?? background,
      logo: detail.logo ?? logo,
      description: detail.description ?? description,
      releaseInfo: detail.releaseInfo ?? releaseInfo,
      imdbRating: detail.imdbRating ?? imdbRating,
      runtime: detail.runtime ?? runtime,
      genres: detail.genres.isNotEmpty ? detail.genres : genres,
      cast: detail.cast.isNotEmpty ? detail.cast : cast,
      directors: detail.directors.isNotEmpty ? detail.directors : directors,
      videos: detail.videos.isNotEmpty ? detail.videos : videos,
      trailerYoutubeIds: detail.trailerYoutubeIds.isNotEmpty ? detail.trailerYoutubeIds : trailerYoutubeIds,
      landscape: detail.landscape || landscape,
    );
  }
}
