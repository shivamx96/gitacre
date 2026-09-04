# gitacre website

The marketing site is deliberately static: no build step, dependencies, analytics, or cookies.

Preview it locally from the repository root:

```sh
python3 -m http.server 8080 --directory website
```

The download buttons remain in a “Public beta soon” state while `releasesEnabled` is `false` in `script.js`. Once the repository is public and the first release exists, enable that flag and the site will automatically link to the latest DMG asset through the public GitHub Releases API.
