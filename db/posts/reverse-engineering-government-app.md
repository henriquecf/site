I've been filling up at the same gas station for years out of habit. One day I checked the price at a station two blocks away and it was 30 centavos cheaper per liter. Over a full tank, that's almost R$20. I'd been leaving money on the table twice a month for no reason.

Brazil actually has an app for this. A state government agency built it in partnership with the tax authority. Gas stations report prices through electronic tax receipts, so the data updates constantly. Open the app, pick a fuel type, and it shows you the cheapest stations nearby, sorted by price. It's genuinely useful.

The problem: the data is trapped in a mobile app. No website, no public API, no CSV export. If you want to compare prices across a city, or track price trends over time, or just get the data into a spreadsheet, you can't. You open the app, look at the screen, close the app.

I wanted the data out. So I opened Claude Code and started pulling the app apart.

## Decompiling the APK

First step: get the APK. I downloaded it from one of the mirror sites that archive Google Play packages. About 22MB.

Then I needed to look inside it. Android APKs are essentially ZIP files containing compiled code, resources, and assets. For native apps, the interesting stuff is in compiled Dalvik bytecode that you'd need to decompile with something like jadx. But not every app is native.

```bash
unzip -d decompiled app.apk
```

I opened the decompiled directory and found `resources/assets/public/`. Inside: `cordova.js`, `main.js`, numbered chunk files like `4293.js`, `7489.js`, `8407.js`. This is a Cordova app. The Android APK is a wrapper around a web application built with Ionic and Angular. The entire application logic is sitting right there as JavaScript in the assets folder.

This changes everything. Instead of reverse-engineering compiled bytecode, I'm reading JavaScript. Minified, yes. But JavaScript. Claude Code can read minified JavaScript just fine.

## Finding the API

I asked Claude Code to search through the decompiled JS for API endpoints, base URLs, and authentication configuration. Within seconds it had pulled out the important pieces: the API base URL hosted on a government subdomain, OAuth configuration pointing to gov.br (Brazil's federal SSO), a client ID, a custom URI scheme for the OAuth redirect, and the required scopes.

The API endpoints were clean and RESTful. Search products by name, search by barcode, fuel prices by type code, price history, list of participating states, token exchange, and token refresh. Query parameters used a consistent prefix with fields for latitude, longitude, radius in kilometers, and fuel type code. The API returns JSON with establishment details, prices, addresses, GPS coordinates.

All of this was right there in the minified JavaScript. No obfuscation beyond standard minification. No certificate pinning. No API key beyond the OAuth token. A government Cordova app built by a state IT company, with the full API surface readable from the APK's asset folder.

## The OAuth wall

Knowing the endpoints is only half the problem. Every API call requires a bearer token, and that token comes from an OAuth 2.0 flow through gov.br, Brazil's federal identity system. You log in with your CPF (national ID number) and password, the way you'd access any government service.

The flow is standard OAuth authorization code:

1. Redirect user to gov.br's authorize endpoint with client ID, redirect URI, and scopes
2. User logs in with CPF + password
3. Gov.br redirects back to the redirect URI with an authorization code
4. Exchange the code for access and refresh tokens at the API's token endpoint

Simple enough for a mobile app. The app opens a browser, the user logs in, the browser redirects to the app's custom URI scheme with a `code` parameter, and the app catches the redirect and extracts the code.

On a desktop, this falls apart. I can't register a custom URI scheme for a random government app. When I opened the authorization URL in Chrome and logged in, gov.br dutifully redirected to the custom scheme URL, and Chrome just showed me a "can't open this page" error. The authorization code was right there in the URL bar, but the redirect "failed."

The workaround is embarrassingly low-tech. Open Chrome DevTools to the Network tab before logging in. Complete the login flow. When the redirect happens, Chrome can't follow it (custom scheme), but the Network tab captures the full redirect URL. Copy the URL, parse out the `code` parameter, paste it into the script.

```python
def login():
    state = _generate_state()
    params = {
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "scope": SCOPES,
        "state": state,
    }
    auth_url = AUTH_URL + "?" + urlencode(params)

    subprocess.Popen(["open", "-a", "Google Chrome", auth_url])

    print("After logging in, the browser will redirect to a custom URI scheme.")
    print("The page won't load — that's expected.")
    print("Copy the full redirect URL from Chrome DevTools > Network tab.")

    callback_url = input("Paste redirect URL: ").strip()
    qs = parse_qs(urlparse(callback_url).query)
    code = qs["code"][0]

    resp = requests.post(TOKEN_URL, data={
        "grant_type": "authorization_code",
        "code": code,
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
    })
    tokens = resp.json()
    save_tokens(tokens)
```

You authenticate once. The script saves the access and refresh tokens to a local config file. When the access token expires, it uses the refresh token automatically. I've been running the scraper for weeks without re-authenticating.

One parameter in the token exchange took a while to figure out. The API requires an extra field that's not part of the OAuth spec, specifying the environment (production vs staging). It's not in any public documentation (there is no public documentation), and the request fails with a generic error if you omit it. The only way to know it exists is to read the decompiled source.

## The older version

I actually decompiled two APK versions. The older one used a different OAuth provider entirely: a state-level identity system. The newer version switched to gov.br, the federal SSO. Same OAuth flow, different identity provider. This is the kind of detail that would waste hours if you only had one version to look at. Comparing the two made the auth architecture obvious.

The endpoint paths didn't change between versions. The app framework did (the newer version's JS files had content-hash filenames, suggesting a more modern build pipeline), but the API surface stayed the same. That's a good sign for stability.

## Building the client

With the auth flow working and the endpoints mapped, building the API client was straightforward. A Python class with methods for each endpoint, automatic token refresh on 401, and CSV export for results.

```python
class FuelPriceClient:
    def __init__(self, tokens=None):
        self.tokens = tokens or load_tokens()
        if not self.tokens.get("access_token"):
            self.tokens = login()

    def _request(self, endpoint, params=None, retry=True):
        url = API_BASE + endpoint
        resp = requests.get(url, params=params, headers={
            "Authorization": f"bearer {self.tokens['access_token']}",
        })

        if resp.status_code == 401 and retry:
            self.tokens = refresh(self.tokens)
            return self._request(endpoint, params, retry=False)

        resp.raise_for_status()
        return resp.json()

    def search_fuel(self, fuel_code, latitude, longitude, km_radius=10):
        return self._request("fuel_endpoint", {
            "fuel_code": fuel_code,
            "latitude": latitude,
            "longitude": longitude,
            "radius_km": km_radius,
            "days": 1,
            "sort": 0,
            "order": 0,
            "platform": "android",
        })
```

A CLI wraps it for interactive use:

```bash
# Search for regular gasoline within 15km of a location
python fuel_prices.py fuel 1 -30.03 -51.22 --km 15

# Search products by name
python fuel_prices.py search "arroz 5kg" -30.03 -51.22
```

Fuel types use regulatory codes: 1 for regular gasoline, 2 for premium, 3 for ethanol, 4 for diesel, 5 for natural gas. The API returns everything about each gas station: tax ID, address, GPS coordinates, price, the date of the last tax receipt, and the distance from your search point.

## Scaling up: the geographic scraper

The basic client searches a radius around a single point. To get fuel prices across an entire state, you'd need to tile the state with overlapping search circles. The API returns results within a configurable radius (5 to 25 km), so you need enough query points that every gas station falls within at least one circle.

I built a scraper that takes a list of municipality coordinates as input and queries fuel prices near each one. The key optimization is geographic coverage deduplication: before querying point B, check if any previous query's center is close enough that B's area is already covered. In metro areas where municipalities are packed together, this cuts the number of queries significantly.

```python
def _is_covered(lat, lng, radius_km, existing_queries):
    """Check if (lat, lng) is within radius_km of any previous query."""
    for qlat, qlng, qradius in existing_queries:
        dist = haversine(lat, lng, qlat, qlng)
        if dist <= qradius:
            return True
    return False
```

Results go into a SQLite database keyed on the unique item code from each tax receipt. The scraper tracks which locations it has already queried, so you can interrupt it and resume later. A staleness parameter controls when old data gets refreshed.

## Pacing

The decompiled app code showed no server-side rate limiting. The only throttling was Firebase analytics on the client side, not API calls. But "no documented rate limit" doesn't mean "fire at will." The API belongs to a government agency, and I'd rather not be the reason they start blocking requests.

The scraper mimics how a person might actually use the app. Thirty to sixty seconds between requests. A longer pause every dozen queries or so. The delays are randomized. It's slower than it needs to be, but it runs unattended and I'm in no rush. A full scan of a state takes a few hours spread across a couple of days.

```python
DELAY_MIN = 30
DELAY_MAX = 60
SHORT_BREAK_EVERY = (8, 15)        # random interval
SHORT_BREAK_SECS  = (2 * 60, 5 * 60)
```

If the API returns an error that looks like throttling, the scraper stops entirely rather than retrying. The next run picks up where it left off.

## What I learned

The whole project, from downloading the APK to a working scraper returning real fuel prices, took an evening. Claude Code did the heavy lifting: reading through minified JavaScript to find endpoints, figuring out the OAuth flow from the decompiled auth configuration, building the Python client, and iterating on the scraper's geographic optimization. I described what I wanted at each step, and it implemented.

A few things stood out.

**Cordova apps are open books.** If an app is built with Cordova, Ionic, React Native, or any framework that ships JavaScript in the APK, the entire application logic is readable. No decompilation of bytecode required. Just unzip the APK and read the JS files. Minification is not obfuscation. API endpoints, auth flows, request formats, error handling, feature flags, everything is there.

**Custom URI scheme OAuth is fragile by design.** Mobile apps rely on custom URI schemes (`myapp://callback`) for OAuth redirects because they can't host a web server. But this means anyone who knows the client ID and redirect URI can initiate the same flow. The security model relies on the scheme being registered to the legitimate app on the device. On a desktop, there's nothing stopping you from completing the flow manually and capturing the code.

**Government APIs are often better than you'd expect.** This API is clean, RESTful, returns well-structured JSON, handles pagination implicitly (it returns all results within the radius), and uses standard OAuth 2.0. It's a solid API. It just doesn't have public documentation or an official way for third parties to access it.

**AI changes the "is it worth building?" calculus.** Before Claude Code, I would have looked at this project and estimated a weekend. Decompiling an APK, reading minified JS, figuring out an undocumented OAuth flow, building a client, handling auth token refresh, geographic optimization for the scraper. Each piece is doable, but the total effort adds up. With Claude Code, the wall-clock time from "I wonder if I can get this data" to "I have fuel prices in a SQLite database" was a few hours. Projects that sit in the "not worth the effort" bucket keep graduating to the "why not, let's try it" bucket.

I still fill up at the same station, by the way. Turns out it was the cheapest one all along. But now I know that for sure.
