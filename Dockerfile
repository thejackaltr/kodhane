# Production image for kodhane.teserix.com (Dokploy). GitHub Pages keeps using .github/workflows/pages.yml.
# Same steps as the Pages build: generate PNG icons, stamp the service worker version, then serve with nginx.
FROM python:3.12-alpine AS build
WORKDIR /site
COPY . .
RUN python3 tools/make_icons.py . \
 && test -s icon-192.png && test -s icon-512.png && test -s apple-touch-icon.png \
 && sed -i "s/__BUILD__/docker-$(date -u +%Y%m%d%H%M%S)/" sw.js \
 && grep -n "var BUILD" sw.js \
 && mkdir /out \
 && cp index.html style.css theme.css game.js fx.js cloud.js leaderboard.js lossreport.js sw.js manifest.webmanifest \
       icon.svg icon-192.png icon-512.png apple-touch-icon.png /out/ \
 && cp -r email /out/

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /out /usr/share/nginx/html
EXPOSE 80
