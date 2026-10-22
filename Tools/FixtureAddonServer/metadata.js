// Stand-in for the TMDB v3 API (/tmdb/3/...) and the TheTVDB v4 API (/tvdb/v4/...) used by the UI tests, so that the
// metadata enrichment and the Settings checks run end to end without a real account and without the network.
//
//   TMDB    accepts the key "fixture-tmdb-key" (as api_key or as a Bearer token); anything else gets HTTP 401 / status_code 7,
//           exactly like the real service answers an invalid key.
//   TheTVDB POST /tvdb/v4/login accepts {"apikey": "fixture-tvdb-key"} and answers a token; a wrong key gets HTTP 401 and
//           "InvalidAPIKey", like the real service. The data endpoints then require "Authorization: Bearer fixture-tvdb-token".
//
// Titles: tt9300001 (a movie whose addon meta is deliberately bare, see server.js) is known to the TMDB stand-in;
// tt9100001 (the fixture series) is known to both.
const TMDB_KEY = 'fixture-tmdb-key';
const TVDB_KEY = 'fixture-tvdb-key';
const TVDB_TOKEN = 'fixture-tvdb-token';

const tmdbMovie = {
  id: 93001, title: 'Sparse Fixture Movie (TMDB)', overview: 'Trama fornita dal servizio TMDB di prova.',
  tagline: 'Un titolo senza dettagli', poster_path: '/p.jpg', backdrop_path: '/b.jpg',
  genres: [{ id: 1, name: 'Fantascienza' }, { id: 2, name: 'Avventura' }], runtime: 97, release_date: '2020-05-05',
  vote_average: 7.4, credits: { cast: [{ id: 1, name: 'Attrice TMDB Uno', character: 'La pilota', order: 0, profile_path: '/p.jpg' },
    { id: 2, name: 'Attore TMDB Due', character: 'Il navigatore', order: 1, profile_path: null }],
    crew: [{ name: 'Regista TMDB', job: 'Director' }] },
  images: { logos: [] }, external_ids: { imdb_id: 'tt9300001' },
  // What the title page shows beyond the overview: status, producers, money, trailers, ratings, similar titles.
  status: 'Released', original_language: 'en', budget: 12000000, revenue: 34500000,
  production_countries: [{ iso_3166_1: 'IT', name: 'Italy' }],
  production_companies: [{ name: 'Studio di Prova', logo_path: '/p.jpg', origin_country: 'IT' }],
  videos: { results: [
    { key: 'FixtureTrl1', site: 'YouTube', type: 'Trailer', name: 'Trailer ufficiale di prova', official: true, iso_639_1: 'it', published_at: '2020-01-01T00:00:00.000Z' },
    { key: 'FixtureTse2', site: 'YouTube', type: 'Teaser', name: 'Teaser di prova', official: true, iso_639_1: 'en', published_at: '2019-12-01T00:00:00.000Z' },
  ] },
  similar: { results: [{ id: 93002, title: 'Titolo simile di prova', poster_path: '/p.jpg', vote_average: 6.5, release_date: '2018-02-02' }] },
  release_dates: { results: [{ iso_3166_1: 'IT', release_dates: [{ certification: 'T', type: 3 }] }] },
};

const tmdbShow = {
  id: 91001, name: 'Fixture Series (TMDB)', overview: 'Trama della serie dal servizio TMDB di prova.', episode_run_time: [42],
  first_air_date: '2023-01-01', genres: [{ id: 3, name: 'Fantascienza' }], poster_path: '/p.jpg', external_ids: { imdb_id: 'tt9100001', tvdb_id: 555 },
};

const tmdbSeason1 = { episodes: [
  { episode_number: 1, season_number: 1, name: 'Pilota (TMDB)', overview: 'Panoramica TMDB episodio 1', still_path: '/s1.jpg' },
  { episode_number: 2, season_number: 1, name: 'Seconda luce (TMDB)', overview: 'Panoramica TMDB episodio 2', still_path: '/s2.jpg' },
] };

const tvdbEpisodes = { status: 'success', data: { episodes: [
  { seasonNumber: 1, number: 1, name: 'Pilota (TVDB)', overview: 'Panoramica TVDB episodio 1', image: null },
  { seasonNumber: 1, number: 2, name: 'Seconda luce (TVDB)', overview: 'Panoramica TVDB episodio 2', image: null },
] }, links: { next: null } };

function handle(req, res, p, url, base, tools) {
  const { send, poster } = tools;

  // ---- image host standing in for image.tmdb.org -------------------------------------------------------------
  if (p.startsWith('/tmdb-img/')) { send(res, 200, poster(7), 'image/png'); return true; }

  // ---- IntroDB (api.introdb.app): the data behind "Salta intro" / "Salta riassunto" -----------------------------------
  // GET /introdb/segments?imdb_id=tt…&season=N&episode=M, no key, the shape the real service answered on 2026-10-21.
  // Only the fixture series (tt9100001) is known: episode 1 has an intro (6 s to 30 s), episode 2 a recap (2 s to 20 s)
  // and an intro (40 s to 70 s); anything else is a 404.
  if (p === '/introdb/segments') {
    const imdb = url.searchParams.get('imdb_id');
    const season = Number(url.searchParams.get('season'));
    const episode = Number(url.searchParams.get('episode'));
    const part = (a, b) => ({ start_sec: a, end_sec: b, start_ms: a * 1000, end_ms: b * 1000, confidence: 1, submission_count: 3,
      updated_at: '2026-01-01T00:00:00.000Z' });
    const answer = { imdb_id: imdb, media_type: 'tv', is_movie: false, season, episode, outro: null, post_credits: null,
      no_intro: false, no_recap: false, no_outro: true };
    if (imdb === 'tt9100001' && season === 1 && episode === 1) {
      send(res, 200, { ...answer, intro: part(6, 30), recap: null, no_recap: true });
    } else if (imdb === 'tt9100001' && season === 1 && episode === 2) {
      send(res, 200, { ...answer, intro: part(40, 70), recap: part(2, 20) });
    } else {
      send(res, 404, { error: 'not found' });
    }
    return true;
  }

  // ---- TMDB ---------------------------------------------------------------------------------------------------
  if (p.startsWith('/tmdb/3/')) {
    const key = url.searchParams.get('api_key');
    const bearer = (req.headers.authorization || '').replace(/^Bearer /, '');
    if (key !== TMDB_KEY && bearer !== TMDB_KEY) {
      send(res, 401, { status_code: 7, status_message: 'Invalid API key: You must be granted a valid key.', success: false });
      return true;
    }
    const route = p.slice('/tmdb/3'.length);
    if (route === '/configuration') {
      send(res, 200, { images: { secure_base_url: `${base}/tmdb-img/`, poster_sizes: ['w92', 'w342', 'w500', 'original'],
        backdrop_sizes: ['w300', 'w780', 'w1280', 'original'], logo_sizes: ['w185', 'w500', 'original'], still_sizes: ['w185', 'w300', 'original'],
        profile_sizes: ['w185', 'h632', 'original'] } });
    } else if (route === '/find/tt9300001') {
      send(res, 200, { movie_results: [{ id: 93001 }], tv_results: [] });
    } else if (route === '/find/tt9100001') {
      send(res, 200, { movie_results: [], tv_results: [{ id: 91001 }] });
    } else if (route.startsWith('/find/')) {
      send(res, 200, { movie_results: [], tv_results: [] });
    } else if (route === '/movie/93001') {
      send(res, 200, tmdbMovie);
    } else if (route === '/movie/93002/external_ids') {
      send(res, 200, { imdb_id: null });
    } else if (route === '/tv/91001') {
      send(res, 200, tmdbShow);
    } else if (route === '/tv/91001/season/1') {
      send(res, 200, tmdbSeason1);
    } else {
      send(res, 404, { status_code: 34, status_message: 'The resource you requested could not be found.', success: false });
    }
    return true;
  }

  // ---- TheTVDB ------------------------------------------------------------------------------------------------
  if (p === '/tvdb/v4/login' && req.method === 'POST') {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      let body = {};
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch (e) { /* answered below */ }
      if (body.apikey === TVDB_KEY) send(res, 200, { status: 'success', data: { token: TVDB_TOKEN } });
      else send(res, 401, { status: 'failure', message: 'InvalidAPIKey: Invalid API key', data: null });
    });
    return true;
  }
  if (p.startsWith('/tvdb/v4/')) {
    if ((req.headers.authorization || '') !== `Bearer ${TVDB_TOKEN}`) {
      send(res, 401, { status: 'failure', message: 'Unauthorized' });
      return true;
    }
    const route = p.slice('/tvdb/v4'.length);
    if (route === '/search/remoteid/tt9100001') send(res, 200, { status: 'success', data: [{ series: { id: 555 } }] });
    else if (route === '/series/555/episodes/default/ita') send(res, 200, tvdbEpisodes);
    else send(res, 404, { status: 'failure', message: 'Not Found' });
    return true;
  }
  return false;
}

module.exports = { handle, TMDB_KEY, TVDB_KEY };
