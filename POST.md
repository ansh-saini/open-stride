---
title: I built the running coach Nike wouldn't, and it runs on my phone
published: false
tags: devchallenge, hf26challenge, ai, ios
---

*This is a submission for the [Hacktoberfest Open-Source AI Challenge: Side Hustle](https://dev.to/challenges/hacktoberfest-week2-2026-10-12)*

## What I Built

I run with Nike Run Club. It tracks every run well, but its plans aren't personal. They don't know my heart rate zones, my actual paces, or what my last few weeks looked like. A tempo session says "comfortably hard" whether my resting heart rate is 50 or 70, and the plan doesn't notice when I miss a week or double my mileage. I wanted a coach that looks at my data and changes the plan because of it.

**OpenStride** is an iOS running coach that reads your data from Apple Health and plans your week around it:

- **Heart rate zones** from your resting HR and the highest HR seen in your own runs (Karvonen)
- **Pace zones** from your best recent effort, or from pace plus heart rate when the effort wasn't all-out (Jack Daniels' VDOT)
- **Training load** per run and your 7-day vs 28-day load ratio
- **HR drift** between the first and second half of each run
- **How much of last week you actually did**

Every week, Gemma (Google's open-weight model) reviews those signals, adjusts the plan, and tells you why in plain words. It runs on the iPhone through MLX, so the app needs no account or server. With the on-device model (the default), your health data stays on the phone.

### Pricing

One-time purchase on the App Store and Google Play: **$10 (₹599 in India)**. No subscription or account needed.

Adaptive training plans are already a paid category (Runna, TrainingPeaks), sold as monthly subscriptions. OpenStride can skip the subscription because the coach runs on the phone: after someone buys it, they cost nothing to serve. The app is iOS only today; the Play Store version comes with Android.

Here's how it would look on the App Store ([full sample listing](https://ansh-saini.github.io/open-stride/appstore/)):

| | | |
|---|---|---|
| ![A coach that reads your body](https://ansh-saini.github.io/open-stride/appstore/web/appstore-1.jpg) | ![It notices when you overdo it](https://ansh-saini.github.io/open-stride/appstore/web/appstore-2.jpg) | ![Runs on your iPhone](https://ansh-saini.github.io/open-stride/appstore/web/appstore-6.jpg) |

## Demo

**Demo page with the full 60 s video: [ansh-saini.github.io/open-stride](https://ansh-saini.github.io/open-stride)**

Recorded on my iPhone with a runner who doubled their mileage last week. Gemma 3 4B runs on the phone; the planning step is sped up.

![OpenStride demo](https://raw.githubusercontent.com/ansh-saini/open-stride/main/screenshots/openstride-demo.gif)

| The week | A session | Signals | What the coach saw |
|---|---|---|---|
| ![plan](https://ansh-saini.github.io/open-stride/media/iphone-week.png) | ![session](https://ansh-saini.github.io/open-stride/media/iphone-session.png) | ![signals](https://ansh-saini.github.io/open-stride/media/iphone-signals.png) | ![prompt](https://ansh-saini.github.io/open-stride/media/iphone-coach-saw.png) |

## Code

{% github ansh-saini/open-stride %}

## How I Built It

I created several modules which work together in steps to deliver an optimial running plan:

1. **CoachKit** (pure Swift, unit tested) computes zones, paces, load and drift, then builds a draft week: phase (base, build, peak, taper), weekly volume, a long run, quality sessions.
2. Code turns the metrics into **signals** with fixed thresholds, each one OK or FLAG. For example: `acute_chronic_load_ratio = 1.98 -> FLAG: above 1.5, injury risk`.
3. **Gemma decides.** It sees the signals and the draft, and picks from a small action set: cut volume, slow easy pace, `make_easy`, `shorten` or `drop` a day, each with a reason.
4. **Guardrails** apply the decision and override anything unsafe. No flag means the draft stands. A flag with too small a response gets a floor. The long run can't be dropped.
5. **Gemma explains.** A second call writes the note from facts that code computed by diffing the draft against the final plan. Code writes the first sentence ("Your heart rate drifted 7.7% during recent runs."), and Gemma continues it. The note always matches what you see.

If the model fails, a rule-based coach writes the week, so the week still gets planned.

### An eval harness

I built six synthetic runners with seeded histories and an expected coach behavior for each:

| Runner | Signal | A good coach should |
|---|---|---|
| steady | all in range | keep progressing |
| overreaching | load ratio 1.98 | cut volume, max one hard day |
| detrained | 21 days off | no hard sessions |
| hr_drift | 7.7% drift | slow easy pace |
| missed_sessions | did 20% of last week | not add volume |
| beginner | 8 km a week | progress gently |

`coach-eval` runs them through Ollama, and `mlx-eval` runs them through the exact MLX weights the phone uses. Each run is scored on whether the decision parsed, whether the final plan is right, whether the model got it right without a guardrail floor, and whether the note cites a real number.

| Coach | Runs | Valid | Final plan right | Model right on its own | Note matches plan | Note cites the flagged number | Avg time |
|---|---|---|---|---|---|---|---|
| rules | 6 | 100% | 100% | 100% | 100% | 100% | 0.0s |
| gemma3:1b (Ollama) | 18 | 100% | 100% | 33% | 100% | 100% | 1.0s |
| gemma3:4b (Ollama) | 18 | 100% | 100% | 100% | 100% | 100% | 4.8s |
| Gemma 3 4B (on-device) | 18 | 100% | 100% | 100% | 100% | 100% | 8.0s |
| Gemma 3 1B (on-device) | 18 | 100% | 100% | 33% | 100% | 100% | 4.3s |

### Real data is messier than test data

My own runs exposed two things the personas didn't. None of my runs from the last four weeks have heart rate recorded, so there's no drift signal, and the coach has to work without it. And my "best effort" wasn't all-out, so the race formula underrated my fitness. Now, when heart rate exists, VDOT is also estimated from pace and heart rate reserve, and the higher estimate wins.

### Stack

SwiftUI, HealthKit, Swift Charts, XCUITest on simulator and device, [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) with `mlx-community/gemma-3-text-4b-it-4bit` (2.6 GB, downloaded once), Ollama for the simulator and evals, XcodeGen.

## Why Does Open Innovation Matter?

**Privacy that holds up.** Heart rate, resting heart rate and VO2 max are health data. With an open-weight model on the device, the coach has no server to send your data to. A closed API needs one.

**Zero marginal cost.** Every plan runs on the phone's GPU. No per-token bill means a solo developer can price this as a one-time purchase instead of a subscription that has to cover inference.

**Works offline.** After the one-time download it works on a trail with no signal, which is where runners are.

**Inspectable and swappable.** The Insights screen shows exactly what the coach saw and what it answered. Because the weights are open, I could test the same model on my Mac, in the simulator and on the phone, and I can swap in a newer Gemma or a fine-tune without changing the app.

## Injury Prevention: The Too-Much-Too-Fast Problem

The most common mistake runners make is doing too much too fast. A good week feels great, so the next one gets longer and faster, and the body's tendons and bones can't keep up with the lungs. A static plan can't see that coming. OpenStride watches for it every week:

- **It measures the jump.** The load ratio compares your last 7 days of training to your 28-day average. Above 1.3, the coach cuts next week's volume by at least 10%. Above 1.5, it cuts at least 20% and allows only one hard session.
- **It progresses slowly.** Weekly volume builds about 8% at a time from your 4-week average, so one big week doesn't become the new normal. A guardrail caps any week at 110% of that average plus 2 km, whatever the model asks for.
- **It plans recovery weeks.** Every fourth week drops volume by 20%.
- **It caps the long run.** The long run can't be more than 15% plus 1 km longer than your longest run in the last four weeks.
- **It spaces hard days.** Hard sessions never fall on back-to-back days, there are at most two a week, and in the base phase, runners under 15 km a week get easy running only.
- **It respects time off.** After 14 or more days without running, the plan starts from half your recent 4-week average with no hard sessions.
- **It listens to your heart.** When your heart rate drifts more than 5% during easy runs, it slows your easy pace.
- **It reacts to missed weeks.** If you finished less than 60% of last week, the next week gets lighter instead of trying to catch up.

In the demo, the runner doubled their mileage in one week (load ratio 1.98). The draft plan had 31 km for the next week; the coach cut it to 25 km, kept one hard day, and explained why in the note.

## My First User

My first user is me. I ran the device test on my own iPhone with two months of my real runs: 22 runs, mostly 3 to 5 km, averaging about 14 km a week.

What it got right: it planned four easy runs and a slightly longer Sunday run, about the same volume I've been doing, at an easy pace close to how I actually run. No signals were flagged, and the note said so instead of inventing a problem.

What it taught me: the first estimate of my fitness was too low, because my "best" run wasn't an all-out effort. That's why the app now also estimates fitness from heart rate. And none of my runs since September 21 have heart rate recorded, so there's no drift to read and the coach is working with less than it could.

## Next Steps

I had a ton of fun building this project as it solves a real problem for me, and I know for a fact that many people face this problem. I'm super excited to integrate this with Apple Watch and seeing how that transforms my running experience. It will give me access to real-time heart rate tracking and session feedback, ensuring the coach receives complete data for more accurate planning. Maybe the coach can say "Hey you're going too fast, slow down" into my earphones during my run itself.

## Prize Categories

- **Best Use of Gemma**: Gemma 3 4B runs on the iPhone through MLX as the coach. Gemma 3 1B and Ollama-served Gemma are the fallbacks.
