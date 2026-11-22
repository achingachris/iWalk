# iWalk field-test checklist

Run these on real devices (iPhone + paired Apple Watch). Plan every route **online beforehand**, then go out with mobile data off.

## Before you go
- [ ] Valhalla server is up and `Local.xcconfig` has `IWALK_BASE_URL` and `IWALK_API_KEY` (Sync tab → Routing server shows "Valhalla").
- [ ] App re-run from Xcode within the last 7 days (free-account apps expire after 7 days; data survives if the bundle ID and team stay the same).
- [ ] Health access granted on both iPhone and Watch. Location set to "While Using".
- [ ] All five routes below are saved, and the Watch shows them (Watch → Sync status → route version equals the phone's).

> Apple has no walking directions in Mombasa, so planning there **only** works with the Valhalla server.

## Offline and sync checks
| # | Check | Pass |
|---|---|---|
| 1 | Airplane mode with Bluetooth on: create a route on the phone → it appears on the Watch | [ ] |
| 2 | Delete a route on the phone → it disappears from the Watch | [ ] |
| 3 | Record on the Watch with the phone left at home → it syncs to the phone's History on return | [ ] |
| 4 | Force-quit both apps mid-sync → nothing lost or duplicated (Watch outbox drains, History shows one entry) | [ ] |
| 5 | Screen locked, no internet, 20 min walk on the phone → track complete, Live Activity updating | [ ] |
| 6 | Edit routes 3 times quickly with the Watch away → on reconnect the Watch shows only the latest version | [ ] |
| 7 | Watch workout with the phone nearby → exactly one session in History and one workout in Health/Fitness | [ ] |
| 8 | Watch workout → the phone shows live stats (mirroring) and the Live Activity says "from Watch" | [ ] |
| 9 | Walk 30+ m off the planned route for 3 fixes → haptic + "Off route" on phone and Watch; clears when back on | [ ] |
| 10 | Route → **Start on Apple Watch** (Watch on wrist, unlocked, phone in Airplane mode with Bluetooth on) → the Watch opens into the route's workout, the phone shows it live, and after ending, Fitness shows one walk/hike/run with the route map | [ ] |
| 11 | Route → **Start on iPhone** (no Watch workout) → on iOS 26+ it runs as a live workout; after Stop → Save, Fitness shows one walk/hike/run with the route map | [ ] |
| 12 | Start on Apple Watch with the Watch off the wrist or out of range → the phone says so within ~20 s and Start on iPhone still works | [ ] |
| 13 | Walk a different path for part of a route (300 m+), offline → after the walk, back online, History shows "Different path from the route"; the walked path follows real streets and its distance is close to what you walked | [ ] |
| 14 | On that walk: **Update** → the saved route changes on the phone and the Watch; **Save as new route** → a "(walked)" route appears; **Keep original** → nothing changes | [ ] |
| 15 | Planner map shows saved routes as dashed purple lines; tapping a route's marker offers Edit in planner; the "Saved" toggle hides them | [ ] |

## Routes
| Route | Activity | What to check | Planned km | Actual km | Within 10%? | Notes |
|---|---|---|---|---|---|---|
| Fort Jesus → Old Town | Walk | Narrow streets, off-route false alarms | | | [ ] | |
| Mama Ngina Drive loop | Run | Distance and pace match between Watch and phone | | | [ ] | |
| Nyali Beach | Walk | GPS near the shore, sand paths | | | [ ] | |
| Haller Park area | Hike | Trail coverage | | | [ ] | |
| Shimba Hills | Hike | Missing OpenStreetMap trails, no network signal | | | [ ] | |

**Done when:** all 5 routes run fully offline and planned distance is within about 10% of actual.

## Issues found
List them, then fix the top 5. Missing paths: add them to OpenStreetMap and rebuild the server (see `server/README.md`).

1.
2.
3.
4.
5.
