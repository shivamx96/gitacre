# gitacre website

The marketing site is deliberately static: no build step, dependencies, analytics, or cookies.

Preview it locally from the repository root:

```sh
python3 -m http.server 8080 --directory website
```

## Docker

Build and run the production container from the repository root:

```sh
docker build --tag gitacre-website:local website
docker run --rm --read-only --tmpfs /tmp --publish 8080:8080 gitacre-website:local
```

Then open <http://localhost:8080>. The container runs NGINX as an unprivileged user, exposes a health check at `/healthz`, and serves only the static website assets.

Alternatively, use Compose from the website directory:

```sh
cd website
docker compose up --build
```

Set `PORT` if port 8080 is already in use, for example `PORT=18080 docker compose up --build`.

The download buttons remain in a “Public beta soon” state while `releasesEnabled` is `false` in `script.js`. Once the repository is public and the first release exists, enable that flag and the site will automatically link to the latest DMG asset through the public GitHub Releases API.
