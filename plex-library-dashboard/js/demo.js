// Sample data shaped like real Plex responses, for trying the dashboard without signing in.
import { normalizeMovies, normalizeEpisodes } from './model.js';

const GB = 1024 ** 3;
const E = '\\\\MEDIA-PC\\PLEX Server';
const F = '\\\\MEDIA-PC\\PLEX (From Other Devices)';
const D = 'D:\\Backup';

function media(file, gb, res, br, ac, ch, extra = {}) {
  return { id: Math.floor(Math.random() * 1e9), videoResolution: res, bitrate: br, videoCodec: 'hevc', audioCodec: ac, audioChannels: ch, container: 'mkv', height: { '4k': 2160, 1080: 1080, 720: 720, sd: 480 }[res], Part: [{ file, size: Math.round(gb * GB) }], ...extra };
}
let rk = 1000;
function movie(title, year, tmdb, medias) { return { ratingKey: String(rk++), title, year, guid: `plex://movie/demo${tmdb}`, Guid: [{ id: `tmdb://${tmdb}` }], addedAt: 1.7e9 + rk * 1000, Media: medias }; }

export function demoSnapshots() {
  const gaming = { id: 'demo-gaming', name: 'GAMING-PC' };
  const movies = [
    movie('Dune', 2021, 438631, [media(`${E}\\Movies\\Dune (2021)\\Dune_t00.mkv`, 70.4, '4k', 82000, 'truehd', 8)]),
    movie('Dune', 2021, 438631, [media(`${D}\\Movies\\Dune (2021) (2160p BluRay x265 10bit HDR Tigole)\\Dune (2021).mkv`, 17.9, '4k', 18000, 'aac', 8)]),
    movie('Dune: Part Two', 2024, 693134, [media(`${E}\\Movies\\Dune - Part Two (2024) (2160p BluRay x265 HEVC 10bit HDR AAC 7.1 Tigole)\\Dune - Part Two (2024).mkv`, 12.8, '4k', 16000, 'aac', 8)]),
    movie('Pirates of the Caribbean: The Curse of the Black Pearl', 2003, 22, [media(`${E}\\Movies\\Pirates of the Caribbean The Curse of the Black Pearl (2003)\\Pirates (2003) [Remux-2160p][HDR10][TrueHD Atmos 7.1].mkv`, 50.3, '4k', 58000, 'truehd', 8)]),
    movie('Kill Bill: Vol. 1', 2003, 24, [media(`${E}\\Movies\\Kill Bill - Vol. 1 (2003)\\Kill Bill - Vol. 1 (2003) (2160p BluRay x265 10bit DV HDR r00t).mkv`, 18.1, '4k', 22000, 'dca', 6)]),
    movie('Kill Bill: Vol. 1', 2003, 24, [media(`${D}\\Movies\\Kill Bill - Vol. 1 (2003)\\Kill Bill - Vol. 1 (2003) (2160p BluRay x265 10bit DV HDR r00t).mkv`, 18.1, '4k', 22000, 'dca', 6)]),
    movie('Titanic', 1997, 597, [media(`${E}\\Movies\\Titanic (1997)\\Titanic (1997) (2160p BluRay x265 10bit HDR Tigole).mkv`, 28.7, '4k', 21000, 'aac', 8)]),
    movie('Spirited Away', 2001, 129, [media(`${E}\\Movies\\[AnimeRG] Spirited Away (2001) [MULTI-AUDIO] [1080p] [x265].mkv`, 4.3, '1080', 5200, 'aac', 6)]),
    movie('The Wizard of Oz', 1939, 630, [
      media(`${E}\\Movies\\The Wizard of Oz (1939)\\The Wizard of Oz (1939) (1080p BluRay x265 HDR afm72).mkv`, 4.6, '1080', 6300, 'aac', 6),
      media(`${E}\\Movies\\The.Wizard.Of.Oz.1939.75th\\The.Wizard.Of.Oz.1939.1080p.BluRay.x264.mp4`, 1.8, '1080', 2500, 'ac3', 6),
    ]),
    movie('Sinners', 2025, 1233413, [media(`${E}\\Movies\\Sinners (2025)\\Sinners (2025) (2160p BluRay x265 10bit DV HDR TrueHD Atmos 7.1 r00t).mkv`, 31.7, '4k', 36000, 'truehd', 8)]),
    movie('Galaxy Quest', 1999, 926, [media(`${E}\\Movies\\Galaxy Quest (1999)\\Galaxy Quest (1999) (2160p BluRay x265 10bit DV HDR r00t).mkv`, 18.6, '4k', 26000, 'truehd', 8)]),
    movie('Toy Story 5', 2026, 1084244, [media(`${E}\\Movies\\Toy.Story.5.2026.1080p.WEB-DL.DDP5.1.mkv`, 2.1, '1080', 3000, 'eac3', 6)]),
    movie('A1', null, 0, [media(`${E}\\Movies\\A1_t00.mkv`, 6.9, 'sd', 8000, 'ac3', 2)]),
    movie('Home Alone', 1990, 771, [media(`${F}\\Movies\\Home Alone (1990) [1080p]\\Home.Alone.1990.1080p.BrRip.x264.YIFY.mp4`, 1.65, '1080', 2200, 'aac', 2)]),
  ];
  Object.assign(movies.find((m) => m.title === 'A1'), { Guid: [], guid: 'local://demo-a1' });

  const shows = [
    { ratingKey: 's1', title: 'Futurama', year: 1999, guid: 'plex://show/demo615', Guid: [{ id: 'tmdb://615' }] },
    { ratingKey: 's2', title: 'The Office (US)', year: 2005, guid: 'plex://show/demo2316', Guid: [{ id: 'tmdb://2316' }] },
    { ratingKey: 's3', title: 'Bob\'s Burgers', year: 2011, guid: 'plex://show/demo32726', Guid: [{ id: 'tmdb://32726' }] },
  ];
  const eps = [];
  const addEps = (showRk, title, season, n, base, gb, res, extraFile) => {
    for (let i = 1; i <= n; i++) {
      eps.push({ ratingKey: String(rk++), grandparentRatingKey: showRk, grandparentTitle: title, parentIndex: season, index: i, title: `Episode ${i}`, addedAt: 1.7e9 + rk,
        Media: [media(`${base}\\Season ${season}\\${title} - S${String(season).padStart(2, '0')}E${String(i).padStart(2, '0')}${extraFile || ''}.mkv`, gb, res, 2500, 'aac', 6)] });
    }
  };
  addEps('s1', 'Futurama', 1, 9, `${E}\\Shows\\Futurama (1999)`, 0.17, '1080');
  addEps('s1', 'Futurama', 2, 20, `${E}\\Shows\\Futurama (1999)`, 0.17, '1080');
  addEps('s2', 'The Office (US)', 1, 6, `${E}\\Shows\\The Office (US) (2005)`, 0.73, '1080');
  addEps('s2', 'The Office (US)', 1, 6, `${F}\\TV\\The Office (2005)`, 0.64, '1080', ' (WEB)');
  addEps('s2', 'The Office (US)', 2, 22, `${E}\\Shows\\The Office (US) (2005)`, 0.73, '1080');
  addEps('s3', 'Bob\'s Burgers', 1, 13, `${E}\\Shows\\Bob's Burgers (2011)`, 0.19, '1080');
  addEps('s3', 'Bob\'s Burgers', 2, 9, `${E}\\Shows\\Bob's Burgers (2011)`, 0.22, '720');

  const now = Date.now();
  return [{
    id: gaming.id, name: gaming.name, lastSeen: now, online: true, demo: true,
    movies: normalizeMovies(movies, gaming, { title: 'Movies' }),
    episodes: normalizeEpisodes(eps, shows, gaming, { title: 'TV Shows' }),
  }];
}
