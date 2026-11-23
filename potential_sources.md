# Potential sources

People keep asking me for more sites, so here's every one I've looked at and whether it can be added.

**The rule:** the plugin has to stay as simple as possible. A site gets in only if it works with **plain API calls** that return JSON. If it needs cookies, tokens, signed requests, scraping web pages or messing with the image files, it's out. No exceptions.

**Logins are fine**, though: they just need a login screen in the plugin (username/password or API key, plus the server address for self-hosted stuff). That screen doesn't exist yet, so those sites are marked 🔑 until it does.

Also keep in mind:
- **Image formats:** KOReader can show JPG, PNG, GIF and WebP. It can't show AVIF*, so sites using it are a pain. The plugin warns you before downloading those.
- **Cloudflare:** if the API sits behind a Cloudflare check, it can't be used.
- **Not tested yet:** except for the sites already in the plugin and Atsumaru, I got everything below from reading the code of [Aidoku's sources](https://github.com/Aidoku-Community/sources), not by trying the APIs myself. So a "Candidate" might turn out not to work once I test it.

✅ In the plugin · 🧪 Added, not tested on a device yet · 🟢 Candidate · 🔑 Login support needed · 🟡 Eh, if you ask enough... · ❌ Out of scope

| Site | Info about the site | Status | Comment |
|---|---|---|---|
| MangaDex | Huge manga library, lots of languages | ✅ | Official public API. |
| nhentai | Adult doujinshi | ✅ | JSON API. |
| archive.org | Old and public-domain comics | ✅ | Public search and metadata APIs. |
| Atsumaru (atsu.moe) | Big English manga/manhwa site | 🧪 | The website has Cloudflare, but the API doesn't. Chapters uploaded since mid-2026 are mostly AVIF, though older ones (and sometimes another group's upload of the same chapter) are WebP. |
| EZManga / QiScans | English manhwa (two sites, one API) | 🟢 | Simple JSON API (`vapi.ezmanga.org`). One port covers both. |
| MangaK / Toontop | English manhwa, lots of adult stuff (two sites, one API) | 🟢 | Simple JSON API (`api.mangak.io`). One port covers both. |
| Chikari | English manga and novels | 🟢 | Simple JSON API. The novels have to be filtered out. |
| Stonescape | Small English scanlation site | 🟡 | Simple JSON API. |
| Guya / Danke.moe | Small scanlation-group sites | 🟡 | Simple JSON API. |
| Cubari | Reader for manga hosted on imgur, gist, etc. | 🟡 | Simple JSON API, but it's for opening links, not browsing. |
| BigSolo | French manga | 🟡 | Simple JSON API. |
| FMTeam | French scanlation group | 🟡 | Simple JSON API (PizzaReader). Other PizzaReader sites would work too. |
| ManhwaWeb | Spanish manhwa | 🟢 | Simple JSON API. Need to check whether its images are AVIF. |
| Olympus Scanlation | Spanish manhwa | 🟡 | Simple JSON API, but the domain keeps changing. |
| Senmanga | Japanese raws | 🟢 | Simple JSON API. |
| CManga | Vietnamese manga | 🟡 | Simple JSON API, but the domain keeps changing. |
| Remanga | Russian manga | 🟡 | JSON API. Free chapters work without logging in; with a login screen you could also read the ones you've paid for. |
| Komga | Your own comic server | 🔑 | REST API with page images. Needs your server's address and your login. Great for western comics you already own. |
| Kavita | Your own comic server | 🔑 | REST API. Needs your server's address and an API key. |
| LANraragi | Your own comic/doujin archive server | 🔑 | REST API. Needs your server's address and an API key. |
| Sumidoku | Your own manga server | 🔑 | REST API with a normal login. |
| Webtoon | Official webtoons, lots of languages | ❌ | Only the chapter list is an API. Search and pages mean scraping web pages and sending cookies, or using the app's API, which needs signed requests. |
| Naver Webtoon | Official Korean webtoons | ❌ | Same as Webtoon: the pages are only on web pages. |
| MangaLib / HentaiLib / SlashLib | Big Russian sites (one API) | ❌ | Every request needs a special `Site-Id` header. |
| InkStory | Russian manga | ❌ | Needs a special client-version header. |
| Mangaball | Multi-language manga | ❌ | The chapter list needs a POST request with a body. |
| Noyacg | Chinese manga | ❌ | POST requests and special headers. |
| Senkuro | Russian manga | ❌ | GraphQL (POST) and cookies. |
| XComic | Adult comics | ❌ | GraphQL (POST). |
| Hitomi | Adult doujinshi | ❌ | To get the image URLs you have to download and run their JS, and it uses AVIF. |
| MANGA Plus | Official Shueisha manga, free | ❌ | App tokens and scrambled images. Shame, because it's legal. |
| Cuutruyen, Zaimanhua, NicoNico Seiga, Soraraw, JMComic, Toonkotsu | Various | ❌ | Their images are scrambled or encrypted. |
| MangaFire | Big multi-language aggregator | ❌ | Needs a generated token for each request. |
| Kagane | Multi-language manga | ❌ | Integrity tokens, and Cloudflare. |
| PicACG | Chinese comics | ❌ | Needs a login, which would be fine, but every request also has to be signed. |
| Komiic | Chinese manga | ❌ | Needs a login, which would be fine, but it looks like it also uses GraphQL (POST). Need to check. |
| Comix, MKissa, MangaDot | Various | ❌ | Captcha or Cloudflare. |
| Comick | Used to be huge | ❌ | Stopped hosting chapters in 2025, so most chapters have no pages. |
| Suwayomi | Your own server running Mihon extensions | ❌ | The login would be fine, but its API is GraphQL (POST). |
| Bato.to / MangaPark | Big aggregators | ❌ | Shut down in January 2026. The ones still online are probably fakes. |
| getcomics.org | Western comics (DC, Marvel...) | ❌ | It's a blog that links to whole CBZ/CBR files, not page images. No API. |
| batcave.biz | Western comics | ❌ | No API, and Cloudflare. |
| nyaa.si | Torrents | ❌ | Torrents don't work on a Kindle. |
| WeebCentral, MangaKakalot, Madara/MangaThemesia sites, and about 140 more | Various | ❌ | No API, only web pages. |
| Any Aidoku source (via their app's engine) | – | ❌ | Would mean shipping a whole WebAssembly runtime. Use [rakuyomi](https://tachibana-shin.github.io/rakuyomi) for that. |

## Want to add one of the candidates?

1. Read its Aidoku source code to find the API addresses: [Aidoku-Community/sources](https://github.com/Aidoku-Community/sources).
2. Try those addresses in a browser or with `curl`. You should get JSON back with no Cloudflare page, and images in JPG, PNG or WebP.
3. Copy `apiko/sources/atsumaru.lua` or `mangadex.lua` and adapt it.
4. Test it on the e-reader. If it works, add it to the READMEs.




*AVIF format integration in KOReader is a pending merge request right now, so in the future it _might_ be supported. Fingers crossed!