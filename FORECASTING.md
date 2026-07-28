# Forecasting Notes

Status: 2026-05-10

This document records the current forecast model understanding and the main open modeling question for future work. It is intentionally detailed enough that a later session can continue without rediscovering the same context.

## Current State

Token Coffee uses the `TokenUsageForecast` Swift package for the displayed weekly quota corridor. The app currently depends on:

```text
TokenUsageForecast 1.1.0
revision 7ab53b2b188bd774b9562cfba94de7ae9a2c6cbf
```

The app passes samples into the package through `TokenUsageForecastAdapter.makeForecastInput(...)`. The package input is built from the current weekly reset window, with samples filtered by:

- matching `limitId`
- matching weekly reset date
- captured inside the current weekly window
- captured no later than `now`

The app now also has an Option-menu diagnostics export path that serializes:

- display projection summary
- package defaults
- exact package input snapshot
- exact package forecast result
- sample counts and first/last input offsets

Use this first when a TestFlight or live build appears to forecast differently from local expectations.

## TokenUsageForecast 1.1.0 Defaults

The package defaults were retuned from prefix backtests over the frozen 72% demo trace and the then-current live 78% trace.

```swift
ForecastParameters(
    maxIdleGapInsideSessionMinutes: 12.6,
    mergeNearbyFutureSessionCandidatesMinutes: 27.2,
    burstThresholdPercentPerHour: 1.41,
    minimumGainForIntenseClusterPercent: 0.48,
    recencyHalfLifeHours: 60,
    linearSessionBlendPercent: 35.3,
    dailyRhythmStrengthPercent: 88.6,
    frequencyAccelerationPercent: 53.3,
    backgroundIdleDriftPercentPerDay: 12.1,
    forecastResolutionMinutes: 10,
    optimisticActivityScale: 0.335,
    pessimisticActivityScale: 2.53,
    includeHeldoutSamples: true,
    includeCandidateDetails: true,
    capForecastAt100Percent: false
)
```

The main intent is to avoid under-warning when the data shows repeated high-activity steps. Higher/more pessimistic forecasts are acceptable; the unacceptable behavior was a model that looked at a clearly risky trace and predicted a harmless endpoint near 96%.

## Evidence For The Current Tuning

The chosen parameters were evaluated over 60...100% prefixes in 1% steps on both:

- frozen bundled demo trace at 72%
- live trace at 78% from the same investigation

The evaluation used the first N% of samples as if only that prefix existed, then forecasted to reset. The chosen set produced:

```text
score 116.91 highMSE 26.22 lowMSE 16.96
corridorHits 76/82 92.7%
endpointHits 79/82 96.3%
exactHits 50/82 61.0%
low range 85.8...106.5
high range 117.2...149.4
```

Representative rows:

```text
DemoQuotaData 72% prefix:
current 53.0 -> low 96.4, high 147.6

DemoQuotaData 100% prefix:
current 72.0 -> low 103.8, high 147.4

Live 72% prefix:
current 53.0 -> low 93.4, high 141.2

Live 100% prefix:
current 78.0 -> low 106.5, high 145.6
```

The bundled demo app capture after the dependency update showed:

```text
72% estimate 104-147%
pace state: slow down
```

That is intentionally more warning-heavy than the old local screenshot range of roughly `96-145%`.

## What The Current Model Captures

The model is not a plain linear extrapolator. It contains several mechanisms that partially reflect visible activity patterns:

1. Session detection

   Positive usage deltas are grouped into usage sessions. With `maxIdleGapInsideSessionMinutes = 12.6`, tight clusters of token use become detected sessions instead of being smeared across long idle gaps.

2. Daily rhythm replay

   With `dailyRhythmStrengthPercent = 88.6`, activity around a time of day strongly influences future same-time-next-day candidates. This is important for a user who mostly uses tokens in a regular daily block, for example between 17:00 and 23:00.

3. Inter-session cadence and acceleration

   `frequencyAccelerationPercent = 53.3` lets future sessions become closer together when observed activity suggests accelerating cadence. This is the current model's main way to express "activity sections get more frequent later in the trace."

4. Session-profile replay

   Candidate sessions use a profile derived from historical session shape. This helps preserve some staircase character instead of only drawing a straight line.

5. Dense forecast output

   `forecastResolutionMinutes = 10` keeps the output curve detailed enough for the app to show visible curvature/steps. The previous 70-minute resolution made the rendered forecast look too much like a simple line.

## What The Current Model Does Not Explicitly Capture

The model still does not have a first-class concept of "fat packed activity islands."

The graph contains orange vertical activity sections. Visually, the important ones appear to:

- get more frequent later in the dataset
- get wider later in the dataset
- get more packed/dense later in the dataset
- repeat with an approximate interval around 1.2 days when looking only at the fat packed sections and ignoring thin incidental sections

The current package can approximate this through session replay, daily rhythm, and frequency acceleration, but it does not explicitly:

- classify thin versus fat activity sections
- ignore thin sections when fitting the dominant recurrence
- measure packedness/density as its own feature
- fit a trend over island width
- fit a trend over island gain or density
- detect a specific non-daily recurrence such as "about every 1.2 days" across only the dominant islands
- generate future islands with increasing width/density
- replay the internal staircase shape of a detected island series as the primary forecast

In short, the current model says:

```text
Recent and intense sessions matter.
Repeat them by daily rhythm and recent cadence.
Let cadence accelerate.
Blend that with some linear trend.
```

The desired future model should be closer to:

```text
Detect dense usage islands.
Classify thin/noisy sections separately from dominant packed sections.
Fit recurrence, width, gain, and density trends over the dominant islands.
Project future islands and replay their internal staircase profiles.
Use linear slope only as a supporting baseline.
```

## Future Direction: Activity Islands

A useful next modeling layer would sit between raw sessions and forecast candidates:

```text
usage samples
  -> positive deltas
  -> sessions
  -> activity islands
  -> recurring island series
  -> forecasted islands
  -> forecast curve
```

Each activity island should probably carry:

- `start`
- `end`
- `duration`
- `totalGain`
- `eventCount`
- `density` / packedness
- `peakIntensity`
- `internalProfile`
- `timeOfDayAnchor`
- `gapFromPreviousDominantIsland`
- `isDominant`

Possible detection approach:

1. Build tight sessions from positive usage deltas.
2. Merge sessions into larger activity islands when the gap between active bursts is short enough relative to the island width or local cadence.
3. Score each island by gain, duration, event count, density, and recency.
4. Mark very thin/low-gain islands as incidental unless they align with the dominant rhythm.
5. Fit one or more dominant island series by recurrence interval and time-of-day alignment.
6. Estimate whether recurrence gaps are shrinking.
7. Estimate whether island width/gain/density are increasing.
8. Generate future islands from the dominant series.
9. Convert future islands into forecast points by replaying their internal staircase profiles.

This would make the model naturally handle a user who only uses tokens in a regular evening block. The ideal forecast for that case should be a staircase that stays mostly flat outside the recurring activity window and rises during the expected active window.

## Current Caution

The current 1.1.0 behavior is acceptable as a warning-oriented heuristic, but it should not be mistaken for the final model shape.

It now avoids the bad failure mode where the high forecast collapsed toward the latest few weak samples. It still does not fully explain the graph the way a human would by looking at dense recurring orange sections.

Future work should avoid only tuning scalar parameters further unless the problem is clearly parameter-only. The next meaningful improvement is likely structural: add an activity-island layer, then retune parameters against the same prefix backtest strategy.

## Useful Verification Commands

Package:

```sh
cd /Users/ap/Projects/TokenUsageForecast
swift test
swift run token-usage-forecast-demo Tests/TokenUsageForecastTests/Resources/DemoQuotaData.json
```

App:

```sh
cd /Users/ap/Projects/TokenCoffee
./Scripts/test.sh
open -n "/Users/ap/Library/Developer/Xcode/DerivedData/TokenCoffee-fjdhpqoolmkeonflhgzdynyxdxco/Build/Products/Debug/Token Coffee.app" --args --demo
brrainztools --app com.pardeike.TokenCoffee --menu-bar-index 0 --capture-menu --output /tmp/tokencoffee-demo.png
```

Expected app demo result with `TokenUsageForecast 1.1.0`:

```text
72% estimate 104-147%
pace state: slow down
```
