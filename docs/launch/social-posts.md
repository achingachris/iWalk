# iWalk launch posts

Replace `ARTICLE_URL` with the article's link once it's published.

## LinkedIn

**Attach:** `docs/screenshots/plan.png`, `docs/screenshots/live-activity.png`, `docs/screenshots/route-review.png`, `docs/screenshots/watch-route.png` (as a 4-image post).

```text
I built an iPhone and Apple Watch app for walking around Mombasa without depending on mobile data.

It's called iWalk, and the idea is simple: plan online, use offline.

You plan a walk, hike or run at home on Wi-Fi. After that, your phone and watch follow it with no internet: live stats, a lock screen Live Activity, an alert when you go off route, and the workout saved to Apple Health. Routes and finished walks sync between phone and watch over Bluetooth.

A few things I learned building it:

• Apple Maps has no walking directions in Mombasa, so routing runs on my own Valhalla server, built from OpenStreetMap data for Kenya with elevation.
• On a real 10 km test walk, the Watch measured 10.71 km against a planned 10.68 km.
• Raw GPS over-counts distance. Ignoring tiny wobbles took my track from 2% too long to within 0.2% of Apple Health.
• Real walks rarely match the plan. If you take a different path, iWalk now offers to update the saved route.

It's a prototype, running on a free Apple developer account. Next up: the trails at Haller Park and Shimba Hills, and adding missing paths to OpenStreetMap.

Write-up: ARTICLE_URL
Code: https://github.com/achingachris/iWalk

#iOS #AppleWatch #SwiftUI #OpenStreetMap #Mombasa #Kenya
```

## X

One long post (X Premium). **Attach:** `docs/screenshots/plan.png`, `docs/screenshots/live-activity.png`, `docs/screenshots/route-review.png`, `docs/screenshots/watch-route.png`.

```text
built an iPhone + Apple Watch app for walking around Mombasa without depending on mobile data. it's called iWalk.

the idea: plan online, use offline.

you plan a walk, hike or run at home on wi-fi. after that, the phone and the watch follow it with zero internet:

• live stats and a lock screen Live Activity
• a buzz on the wrist when you go more than 30 m off route
• the workout saved to Apple Health, route map included
• routes and finished walks synced between phone and watch over Bluetooth

why build it? Apple Maps has no walking directions in Mombasa. ask it for one and you get "Walking Directions Not Available". so routing runs on my own Valhalla server, built from OpenStreetMap data for Kenya, with elevation. the route and its elevation profile are saved on the device, so the walk itself needs no signal.

first real test was a 10 km walk. the watch measured 10.71 km against a planned 10.68 km. a GPS fix every 2 seconds, median accuracy 4 m.

the data taught me a few things:

• raw GPS over-counts. summing every tiny wobble made my track 2% too long. ignoring steps under 5 m brought it within 0.2% of Apple Health.
• real walks rarely match the plan. i took a different path for about 2.9 km, so iWalk now matches your track to real paths afterwards and offers to update the saved route, save it as a new one, or keep the original.
• walks started without a route now link to the saved route they actually followed, instead of becoming duplicates.

it's a prototype on a free Apple developer account, so no push notifications, no iCloud, and apps that expire every 7 days. everything leans on local storage and device to device sync.

next: the trails at Haller Park and Shimba Hills, and adding the paths OpenStreetMap is missing.

write-up: ARTICLE_URL
code: github.com/achingachris/iWalk
```
