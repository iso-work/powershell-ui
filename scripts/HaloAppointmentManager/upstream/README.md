# Halo Appointment Manager (Edge/Chrome extension)

Adds an **📅 Appointment Manager** button to the Halo Calendar page (https://support.isoutsource.com/calendar) that lists your Halo
appointments in Past open / Upcoming / Completed / All tabs, with single and bulk Complete, Delete,
Edit and Open actions. Reuses the bearer token from your logged-in Halo tab (captured in memory only) — no stored credentials or Exchange access.

## Install
1. Unzip to a permanent folder.
2. Edge: `edge://extensions` (Chrome: `chrome://extensions`) → enable **Developer mode**.
3. **Load unpacked** → select the folder.
4. Refresh Halo. The button appears bottom-right.

## First run
- Uses the logged-in Halo agent automatically (via `/api/Agent/me`, falling back to the session token). Settings → Agent ID override is only for viewing another agent; leave blank otherwise.
- Adjust past/future day range, follow-up behaviour in Settings. Completion always defaults to the **Do Not Bill** charge rate.

## API calls (from captured HARs)
| Action   | Request |
|----------|---------|
| List     | `GET /api/Appointment?...` (same parameters as the Halo calendar) |
| Complete | `POST /api/Appointment` with `[ {id, ..., complete_status:"0", chargerate, complete_date, utcoffset} ]` |
| Delete   | `DELETE /api/Appointment/{id}` |
| Rates    | `GET /api/lookup?lookupid=17&use=0` |

## Safety
- Buttons honour Halo's own `_cancomplete`, `_candelete`, `_canupdate` flags.
- Bulk actions run one at a time with a success/failure log; delete requires a confirmation tick.
- Recurring occurrences are labelled; only the occurrence is acted on, never the series.

## Test before bulk use
- **Complete without follow-up** (follow-up unticked) — the captured HAR included follow-up fields; verify on one item.
- **Edit** is experimental (same POST endpoint, payload not captured); test on one appointment.
- **/api/agent/me** auto-detection is not proven in the HARs; Settings fallback covers it.
