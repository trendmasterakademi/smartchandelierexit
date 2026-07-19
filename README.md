# Smart Chandelier Exit

## Overview
Smart Chandelier Exit is an adaptive trailing-stop and trend-direction indicator for MetaTrader 5 (MQL5).
It plots a single stop line that follows price: green below price in an uptrend, red above price in a downtrend. The line only ever ratchets in the trend's favor, never against it, so it doubles as a mechanical stop-loss and a trend-state signal.

What makes it "smart" is the built-in **Pearson R trend-quality filter**. A raw stop line tells you WHERE the stop is; the Pearson R engine tells you HOW GOOD the current trend actually is (strong, moderate, weak, or just ranging noise). Both are shown together on a compact on-chart panel, along with rolling statistics that separate genuine trend flips from short-lived "fake" flips.

The indicator is **non-repainting**: the stop line is computed on closed bars with a one-directional ratchet, alerts fire only on a closed bar, and flip arrows are confirmed after a fixed number of bars.

## What You See on the Chart
1. **Stop Line (the main plot)**
   - Green line ("CE Long SL"): the trailing stop while the trend is UP. It sits below price and can only move up.
   - Red line ("CE Short SL"): the trailing stop while the trend is DOWN. It sits above price and can only move down.
   - *Only one of the two is visible at any time.*

2. **Flip Arrows (optional)**
   - Green up-arrow below the bar: confirmed flip to bullish.
   - Red down-arrow above the bar: confirmed flip to bearish.
   - Arrows are drawn only AFTER the flip has survived `InpFakeFlipBars` bars. This confirmation delay filters out flips that instantly reverse.

3. **Info Panel (optional)**
   - Shows the current direction, stop distance (in points/pips and ATR units), trend quality (Pearson R), and flip statistics.

## Input Parameters
### CE Parameters
* `InpATRPeriod` (22): ATR period used to size the stop distance.
* `InpLookback` (22): Number of bars used for the highest-high / lowest-low that the stop is measured from.
* `InpMultiplier` (3.0): ATR multiplier. Larger = wider stop, fewer flips.

### Pearson R (Trend Quality)
* `InpRPeriod` (22): Lookback for the price-vs-time correlation.
* `InpRStrongLevel` (0.7): |R| at/above this = "Strong" regime.
* `InpRModerateLevel` (0.5): |R| at/above this = "Moderate" regime.

### Visual & Other Settings
* `InpFakeFlipBars` (5): A flip that reverses within this many bars is tagged FAKE. Also the confirmation delay for drawing arrows.
* Panel visibility, colors, fonts, and alert settings are completely customizable.

## Suggested Use
- **Trend direction / bias**: Trade in the direction of the active stop line.
- **Trailing stop**: Use the plotted line as a mechanical stop that never loosens.
- **Quality filter**: Prefer signals when the regime is Strong or Moderate in the trade direction, and be cautious when the panel reads RANGING.
- **Flip trust**: Use the rolling statistics gauge and the Pearson R momentum arrow to judge whether a fresh flip is likely genuine or a counter-trend trap.

> **Disclaimer**: This is an indicator for analysis and decision support. It does not place trades. Always test thoroughly before using any tool in live trading. Trading involves risk.
