#include "EQComponent.h"

namespace
{
    const juce::Colour kChrome (0xffd8dee6);
    const juce::Colour kCream  (0xfffffbf2);
    const juce::Colour kCyan   (0xff6fe3e0);

    juce::Font eqFont (float size)
    {
        return juce::Font (juce::FontOptions ("Avenir Next", size, juce::Font::plain))
                   .withTypefaceStyle ("Regular");
    }

    juce::String freqLabel (float hz)
    {
        return hz >= 1000.0f ? juce::String (hz / 1000.0f, hz >= 10000.0f ? 0 : 0) + "k"
                             : juce::String ((int) hz);
    }
}

EQComponent::EQComponent (ResonanceAudioProcessor& p) : proc (p)
{
    setWantsKeyboardFocus (false);
}

juce::Rectangle<float> EQComponent::graphArea() const
{
    return getLocalBounds().toFloat().reduced (14.0f);
}

float EQComponent::freqToX (float hz) const
{
    auto ga = graphArea();
    const float n = std::log (juce::jlimit (kMinFreq, kMaxFreq, hz) / kMinFreq) / std::log (kMaxFreq / kMinFreq);
    return ga.getX() + n * ga.getWidth();
}

float EQComponent::xToFreq (float px) const
{
    auto ga = graphArea();
    const float n = juce::jlimit (0.0f, 1.0f, (px - ga.getX()) / ga.getWidth());
    return kMinFreq * std::pow (kMaxFreq / kMinFreq, n);
}

float EQComponent::gainToY (float db) const
{
    auto ga = graphArea();
    const float n = (juce::jlimit (-kDbSpan, kDbSpan, db) + kDbSpan) / (2.0f * kDbSpan);
    return ga.getBottom() - n * ga.getHeight();
}

float EQComponent::yToGain (float py) const
{
    auto ga = graphArea();
    const float n = juce::jlimit (0.0f, 1.0f, (ga.getBottom() - py) / ga.getHeight());
    return n * 2.0f * kDbSpan - kDbSpan;
}

float EQComponent::bandValue (int band, const char* suffix) const
{
    if (auto* raw = proc.apvts.getRawParameterValue (ResonanceAudioProcessor::bandParamID (band, suffix)))
        return raw->load();
    return 0.0f;
}

void EQComponent::setBandValue (int band, const char* suffix, float value)
{
    if (auto* param = proc.apvts.getParameter (ResonanceAudioProcessor::bandParamID (band, suffix)))
        param->setValueNotifyingHost (param->convertTo0to1 (value));
}

void EQComponent::beginGesture (int band, const char* suffix)
{
    if (auto* param = proc.apvts.getParameter (ResonanceAudioProcessor::bandParamID (band, suffix)))
        param->beginChangeGesture();
}

void EQComponent::endGesture (int band, const char* suffix)
{
    if (auto* param = proc.apvts.getParameter (ResonanceAudioProcessor::bandParamID (band, suffix)))
        param->endChangeGesture();
}

juce::Point<float> EQComponent::nodeCentre (int band) const
{
    const float freq = bandValue (band, "freq");
    const int   type = (int) bandValue (band, "type");
    const float gain = bandUsesGain (type) ? bandValue (band, "gain") : 0.0f;
    return { freqToX (freq), gainToY (gain) };
}

int EQComponent::hitNode (juce::Point<float> p) const
{
    for (int i = 0; i < ResonanceEngine::kNumBands; ++i)
    {
        if (bandValue (i, "on") < 0.5f) continue;
        if (nodeCentre (i).getDistanceFrom (p) <= 11.0f) return i;
    }
    return -1;
}

double EQComponent::magnitudeAt (double freq) const
{
    const double sr = proc.getSampleRate() > 0.0 ? proc.getSampleRate() : 48000.0;
    using Coeffs = juce::dsp::IIR::Coefficients<float>;

    double mag = 1.0;
    for (int i = 0; i < ResonanceEngine::kNumBands; ++i)
    {
        if (bandValue (i, "on") < 0.5f) continue;
        const float f = juce::jlimit (20.0f, (float) (sr * 0.45), bandValue (i, "freq"));
        const float q = juce::jlimit (0.05f, 18.0f, bandValue (i, "q"));
        const float g = juce::Decibels::decibelsToGain (bandValue (i, "gain"));

        Coeffs::Ptr c;
        switch ((int) bandValue (i, "type"))
        {
            case ResonanceEngine::LowCut:    c = Coeffs::makeHighPass  (sr, f, q);    break;
            case ResonanceEngine::LowShelf:  c = Coeffs::makeLowShelf  (sr, f, q, g); break;
            case ResonanceEngine::HighShelf: c = Coeffs::makeHighShelf (sr, f, q, g); break;
            case ResonanceEngine::HighCut:   c = Coeffs::makeLowPass   (sr, f, q);    break;
            default:                         c = Coeffs::makePeakFilter (sr, f, q, g); break;
        }
        mag *= c->getMagnitudeForFrequency (juce::jmin (freq, sr * 0.45), sr);
    }
    return mag;
}

juce::uint64 EQComponent::paramFingerprint() const
{
    juce::uint64 h = 1469598103934665603ULL;
    auto mixIn = [&h] (float v)
    {
        juce::uint32 bits;
        std::memcpy (&bits, &v, sizeof (bits));
        h ^= bits; h *= 1099511628211ULL;
    };
    for (int i = 0; i < ResonanceEngine::kNumBands; ++i)
    {
        mixIn (bandValue (i, "on"));
        mixIn (bandValue (i, "type"));
        mixIn (bandValue (i, "freq"));
        mixIn (bandValue (i, "gain"));
        mixIn (bandValue (i, "q"));
    }
    mixIn ((float) selected);
    return h;
}

void EQComponent::refreshIfChanged()
{
    const auto fp = paramFingerprint();
    if (fp != lastFingerprint)
    {
        lastFingerprint = fp;
        rebuildCurve();
        repaint();
    }
}

void EQComponent::setSelectedBand (int band)
{
    selected = juce::jlimit (0, ResonanceEngine::kNumBands - 1, band);
    if (onSelectBand) onSelectBand (selected);
    repaint();
}

void EQComponent::rebuildCurve()
{
    auto ga = graphArea();
    curve.clear();
    const int steps = juce::jmax (2, (int) ga.getWidth());
    for (int i = 0; i <= steps; ++i)
    {
        const float x  = ga.getX() + ga.getWidth() * (float) i / (float) steps;
        const double m = magnitudeAt ((double) xToFreq (x));
        const float db = (float) juce::Decibels::gainToDecibels (m, -60.0);
        const juce::Point<float> pt (x, gainToY (db));
        if (i == 0) curve.startNewSubPath (pt);
        else        curve.lineTo (pt);
    }
}

void EQComponent::paint (juce::Graphics& g)
{
    auto area = getLocalBounds().toFloat();
    auto ga   = graphArea();

    g.setColour (juce::Colour (0x33060a12));
    g.fillRoundedRectangle (area, 16.0f);

    // frequency grid + labels
    const float gridFreqs[]  = { 30, 40, 50, 60, 80, 100, 200, 300, 400, 500, 600, 800,
                                 1000, 2000, 3000, 4000, 5000, 6000, 8000, 10000 };
    const float labelFreqs[] = { 50, 100, 200, 500, 1000, 2000, 5000, 10000 };

    g.setColour (kChrome.withAlpha (0.05f));
    for (float f : gridFreqs)
    {
        const float x = freqToX (f);
        g.drawLine (x, ga.getY(), x, ga.getBottom(), 1.0f);
    }

    // gain grid: emphasized zero line, soft ±6/±12
    for (float db : { -12.0f, -6.0f, 0.0f, 6.0f, 12.0f })
    {
        const float y = gainToY (db);
        g.setColour (kChrome.withAlpha (db == 0.0f ? 0.14f : 0.05f));
        g.drawLine (ga.getX(), y, ga.getRight(), y, 1.0f);
    }

    g.setFont (eqFont (9.0f));
    g.setColour (kChrome.withAlpha (0.35f));
    for (float f : labelFreqs)
        g.drawText (freqLabel (f), (int) freqToX (f) - 16, (int) ga.getBottom() + 1, 32, 11,
                    juce::Justification::centred);
    for (float db : { -12.0f, 0.0f, 12.0f })
        g.drawText (juce::String ((int) db), (int) ga.getX() - 13, (int) gainToY (db) - 6, 24, 12,
                    juce::Justification::left);

    if (curve.isEmpty()) rebuildCurve();

    // gradient fill under the response curve
    juce::Path fill = curve;
    fill.lineTo (ga.getRight(), ga.getBottom());
    fill.lineTo (ga.getX(), ga.getBottom());
    fill.closeSubPath();
    juce::ColourGradient fg (kCyan.withAlpha (0.20f), ga.getCentreX(), ga.getY(),
                             kCyan.withAlpha (0.02f), ga.getCentreX(), ga.getBottom(), false);
    g.setGradientFill (fg);
    g.fillPath (fill);

    // glowing response stroke
    for (int i = 3; i >= 1; --i)
    {
        g.setColour (kCyan.withAlpha (0.10f));
        g.strokePath (curve, juce::PathStrokeType (2.0f + (float) i * 2.0f,
                      juce::PathStrokeType::curved, juce::PathStrokeType::rounded));
    }
    g.setColour (kCyan.withAlpha (0.95f));
    g.strokePath (curve, juce::PathStrokeType (2.0f, juce::PathStrokeType::curved, juce::PathStrokeType::rounded));

    // nodes
    for (int i = 0; i < ResonanceEngine::kNumBands; ++i)
    {
        if (bandValue (i, "on") < 0.5f) continue;
        const auto pt = nodeCentre (i);
        const bool sel = i == selected;
        const auto col = sel ? kCyan : kCream;

        g.setColour (col.withAlpha (sel ? 0.35f : 0.25f));
        const float glowD = sel ? 18.0f : 14.0f;
        g.fillEllipse (pt.x - glowD * 0.5f, pt.y - glowD * 0.5f, glowD, glowD);
        g.setColour (col);
        const float coreD = sel ? 9.0f : 8.0f;
        g.fillEllipse (pt.x - coreD * 0.5f, pt.y - coreD * 0.5f, coreD, coreD);

        g.setFont (eqFont (9.0f));
        g.setColour (col.withAlpha (0.8f));
        g.drawText (juce::String (i + 1), (int) pt.x - 8, (int) pt.y - 20, 16, 11,
                    juce::Justification::centred);
    }

    // gesture hints
    g.setFont (eqFont (9.0f));
    g.setColour (kChrome.withAlpha (0.35f));
    g.drawText ("double-click adds a node · right-click removes · wheel shapes Q",
                (int) ga.getX(), (int) ga.getY() - 11, (int) ga.getWidth(), 11,
                juce::Justification::centredRight);
}

void EQComponent::mouseDown (const juce::MouseEvent& e)
{
    const int n = hitNode (e.position);

    if (e.mods.isPopupMenu())
    {
        if (n >= 0)
        {
            setBandValue (n, "on", 0.0f);
            rebuildCurve();
            repaint();
        }
        return;
    }

    if (n >= 0)
    {
        dragBand = n;
        setSelectedBand (n);
        beginGesture (n, "freq");
        if (bandUsesGain ((int) bandValue (n, "type"))) beginGesture (n, "gain");
    }
}

void EQComponent::mouseDrag (const juce::MouseEvent& e)
{
    if (dragBand < 0) return;

    const float fine = e.mods.isShiftDown() ? 0.25f : 1.0f;
    const float freq = xToFreq (e.position.x);
    setBandValue (dragBand, "freq", freq);

    if (bandUsesGain ((int) bandValue (dragBand, "type")))
    {
        const float target = yToGain (e.position.y);
        const float current = bandValue (dragBand, "gain");
        setBandValue (dragBand, "gain", current + (target - current) * fine);
    }
    rebuildCurve();
    repaint();
}

void EQComponent::mouseUp (const juce::MouseEvent&)
{
    if (dragBand >= 0)
    {
        endGesture (dragBand, "freq");
        if (bandUsesGain ((int) bandValue (dragBand, "type"))) endGesture (dragBand, "gain");
        dragBand = -1;
    }
}

void EQComponent::mouseDoubleClick (const juce::MouseEvent& e)
{
    const int n = hitNode (e.position);
    if (n >= 0)
    {
        setBandValue (n, "on", 0.0f);
        rebuildCurve();
        repaint();
        return;
    }

    for (int i = 0; i < ResonanceEngine::kNumBands; ++i)
    {
        if (bandValue (i, "on") > 0.5f) continue;
        setBandValue (i, "on", 1.0f);
        setBandValue (i, "type", (float) ResonanceEngine::Bell);
        setBandValue (i, "freq", xToFreq (e.position.x));
        setBandValue (i, "gain", yToGain (e.position.y));
        setBandValue (i, "q", 1.0f);
        setSelectedBand (i);
        break;
    }
    rebuildCurve();
    repaint();
}

void EQComponent::mouseWheelMove (const juce::MouseEvent& e, const juce::MouseWheelDetails& wheel)
{
    int target = hitNode (e.position);
    if (target < 0) target = selected;
    if (target < 0 || bandValue (target, "on") < 0.5f) return;

    const float q = bandValue (target, "q");
    const float scaled = juce::jlimit (0.1f, 10.0f, q * (1.0f + wheel.deltaY * 0.6f));
    setBandValue (target, "q", scaled);
    rebuildCurve();
    repaint();
}
