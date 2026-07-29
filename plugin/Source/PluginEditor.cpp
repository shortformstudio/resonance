#include "PluginEditor.h"

namespace
{
    // palette: dark navy/black base, chrome + cream + cyan accents
    const juce::Colour kNavy   (0xff0a0e16);
    const juce::Colour kChrome (0xffd8dee6);
    const juce::Colour kCream  (0xfffffbf2);
    const juce::Colour kCyan   (0xff6fe3e0);

    juce::Font softFont (float size, const char* style = "Medium")
    {
        return juce::Font (juce::FontOptions ("Avenir Next", size, juce::Font::plain))
                   .withTypefaceStyle (style);
    }

    void drawGlowText (juce::Graphics& g, const juce::String& text, juce::Rectangle<int> area,
                       juce::Justification just, juce::Colour cream, float glow)
    {
        for (int i = 6; i >= 1; --i)
        {
            const float spread = (float) i * glow;
            g.setColour (cream.withAlpha (0.10f));
            for (float a = 0.0f; a < juce::MathConstants<float>::twoPi; a += juce::MathConstants<float>::halfPi)
                g.drawText (text, area.translated ((int) (std::cos (a) * spread), (int) (std::sin (a) * spread)), just);
        }
        g.setColour (cream);
        g.drawText (text, area, just);
    }

    // soft rounded translucent panel with a faint top highlight
    void glassPanel (juce::Graphics& g, juce::Rectangle<float> r, float radius = 22.0f)
    {
        juce::ColourGradient grad (juce::Colour (0x33121826), r.getCentreX(), r.getY(),
                                   juce::Colour (0x120a0e16), r.getCentreX(), r.getBottom(), false);
        g.setGradientFill (grad);
        g.fillRoundedRectangle (r, radius);
        g.setColour (kChrome.withAlpha (0.14f));
        g.drawRoundedRectangle (r.reduced (0.5f), radius, 1.0f);
        g.setColour (kCream.withAlpha (0.06f));
        g.drawRoundedRectangle (r.reduced (1.5f).withTrimmedBottom (r.getHeight() * 0.5f), radius, 1.2f);
    }

    struct BandSetting { int type; float freq, gain, q; };
    struct InstrumentPreset { const char* name; BandSetting bands[4]; };

    const InstrumentPreset kInstruments[] = {
        { "Manual / Flat",     { { ResonanceEngine::LowShelf,    90, 0.0f, 0.71f }, { ResonanceEngine::Bell,  250,  0.0f, 1.0f }, { ResonanceEngine::Bell, 3000,  0.0f, 1.0f  }, { ResonanceEngine::HighShelf, 10000, 0.0f, 0.71f } } },
        { "Vocal",             { { ResonanceEngine::LowCut,      80, 0.0f, 0.71f }, { ResonanceEngine::Bell,  240, -1.5f, 1.0f }, { ResonanceEngine::Bell, 3200,  2.5f, 0.9f  }, { ResonanceEngine::HighShelf, 11000, 2.0f, 0.71f } } },
        { "Voice · Podcast",   { { ResonanceEngine::LowCut,      90, 0.0f, 0.71f }, { ResonanceEngine::Bell,  220, -2.0f, 1.0f }, { ResonanceEngine::Bell, 3000,  3.0f, 0.8f  }, { ResonanceEngine::HighShelf, 10000, 1.0f, 0.71f } } },
        { "Piano",             { { ResonanceEngine::LowShelf,    90, -1.0f, 0.71f }, { ResonanceEngine::Bell,  300, -1.5f, 1.1f }, { ResonanceEngine::Bell, 2500,  1.5f, 1.0f  }, { ResonanceEngine::HighShelf, 10000, 1.5f, 0.71f } } },
        { "Acoustic Guitar",   { { ResonanceEngine::LowCut,      70, 0.0f, 0.71f }, { ResonanceEngine::Bell,  200, -2.0f, 1.0f }, { ResonanceEngine::Bell, 5000,  2.0f, 1.0f  }, { ResonanceEngine::HighShelf, 11000, 1.5f, 0.71f } } },
        { "Electric Guitar",   { { ResonanceEngine::LowCut,      80, 0.0f, 0.71f }, { ResonanceEngine::Bell,  450, -1.5f, 1.0f }, { ResonanceEngine::Bell, 3500,  2.0f, 0.9f  }, { ResonanceEngine::HighCut,   10000, 0.0f, 0.71f } } },
        { "Bass",              { { ResonanceEngine::LowShelf,    60, 2.0f, 0.71f }, { ResonanceEngine::Bell,  180, -1.0f, 1.0f }, { ResonanceEngine::Bell,  800,  1.5f, 1.0f  }, { ResonanceEngine::HighCut,    8000, 0.0f, 0.71f } } },
        { "Drum Bus",          { { ResonanceEngine::LowShelf,    60, 2.0f, 0.71f }, { ResonanceEngine::Bell,  400, -2.0f, 1.0f }, { ResonanceEngine::Bell, 4000,  2.0f, 0.9f  }, { ResonanceEngine::HighShelf, 10000, 2.0f, 0.71f } } },
        { "Synth",             { { ResonanceEngine::LowShelf,    80, 1.0f, 0.71f }, { ResonanceEngine::Bell,  500, -1.5f, 1.0f }, { ResonanceEngine::Bell, 6000,  1.5f, 1.0f  }, { ResonanceEngine::HighShelf, 12000, 2.0f, 0.71f } } },
        { "Strings",           { { ResonanceEngine::LowCut,      90, 0.0f, 0.71f }, { ResonanceEngine::Bell,  350, -1.5f, 1.0f }, { ResonanceEngine::Bell, 2000,  1.0f, 1.0f  }, { ResonanceEngine::HighShelf,  9000, 1.5f, 0.71f } } },
        { "Full Mix",          { { ResonanceEngine::LowShelf,    90, 1.0f, 0.71f }, { ResonanceEngine::Bell,  300, -1.0f, 0.8f }, { ResonanceEngine::Bell, 3000,  1.0f, 0.8f  }, { ResonanceEngine::HighShelf, 11000, 1.5f, 0.71f } } },
    };
    constexpr int kNumInstruments = (int) (sizeof (kInstruments) / sizeof (kInstruments[0]));
}

// ============================================================================
SoftLNF::SoftLNF()
{
    setColour (juce::PopupMenu::backgroundColourId,             juce::Colour (0xef0a0e16));
    setColour (juce::PopupMenu::textColourId,                   kCream);
    setColour (juce::PopupMenu::highlightedBackgroundColourId,  kCyan.withAlpha (0.25f));
    setColour (juce::PopupMenu::highlightedTextColourId,        kCream);
    setColour (juce::Slider::textBoxTextColourId,               kCream);
}

void SoftLNF::drawRotarySlider (juce::Graphics& g, int x, int y, int w, int h,
                                float pos, float a0, float a1, juce::Slider&)
{
    auto b = juce::Rectangle<float> ((float) x, (float) y, (float) w, (float) h).reduced (6.0f);
    const float radius = juce::jmin (b.getWidth(), b.getHeight()) * 0.5f;
    const auto c = b.getCentre();
    const float thick = juce::jmax (3.0f, radius * 0.16f);
    const float angle = a0 + pos * (a1 - a0);

    juce::Path track;
    track.addCentredArc (c.x, c.y, radius, radius, 0.0f, a0, a1, true);
    g.setColour (kChrome.withAlpha (0.16f));
    g.strokePath (track, juce::PathStrokeType (thick, juce::PathStrokeType::curved, juce::PathStrokeType::rounded));

    juce::Path val;
    val.addCentredArc (c.x, c.y, radius, radius, 0.0f, a0, angle, true);
    for (int i = 3; i >= 1; --i)
    {
        g.setColour (kCyan.withAlpha (0.10f));
        g.strokePath (val, juce::PathStrokeType (thick + (float) i * 2.5f,
                      juce::PathStrokeType::curved, juce::PathStrokeType::rounded));
    }
    g.setColour (kCyan.withAlpha (0.9f));
    g.strokePath (val, juce::PathStrokeType (thick, juce::PathStrokeType::curved, juce::PathStrokeType::rounded));

    g.setColour (kNavy.withAlpha (0.5f));
    g.fillEllipse (juce::Rectangle<float> (radius * 1.15f, radius * 1.15f).withCentre (c));
    const juce::Point<float> dot (c.x + std::cos (angle) * (radius - thick),
                                  c.y + std::sin (angle) * (radius - thick));
    g.setColour (kCream);
    g.fillEllipse (juce::Rectangle<float> (thick * 1.1f, thick * 1.1f).withCentre (dot));
}

void SoftLNF::drawLinearSlider (juce::Graphics& g, int x, int y, int w, int h,
                                float pos, float, float, juce::Slider::SliderStyle style, juce::Slider& s)
{
    if (style != juce::Slider::LinearHorizontal)
    {
        juce::LookAndFeel_V4::drawLinearSlider (g, x, y, w, h, pos, 0, 0, style, s);
        return;
    }

    auto r = juce::Rectangle<float> ((float) x, (float) y, (float) w, (float) h);
    const float cy = r.getCentreY();
    auto track = juce::Rectangle<float> (r.getX(), cy - 3.0f, r.getWidth(), 6.0f);

    g.setColour (kChrome.withAlpha (0.16f));
    g.fillRoundedRectangle (track, 3.0f);

    // centre detent tick at 0 dB for symmetric ranges
    const float centreX = r.getX() + r.getWidth() * 0.5f;
    g.setColour (kChrome.withAlpha (0.30f));
    g.drawLine (centreX, cy - 7.0f, centreX, cy + 7.0f, 1.0f);

    auto fillFrom = juce::jmin (centreX, pos);
    auto fillTo   = juce::jmax (centreX, pos);
    auto valRect  = juce::Rectangle<float> (fillFrom, cy - 3.0f, juce::jmax (2.0f, fillTo - fillFrom), 6.0f);
    for (int i = 3; i >= 1; --i)
    {
        g.setColour (kCyan.withAlpha (0.10f));
        g.fillRoundedRectangle (valRect.expanded ((float) i * 2.0f, (float) i * 1.5f), 5.0f);
    }
    g.setColour (kCyan.withAlpha (0.9f));
    g.fillRoundedRectangle (valRect, 3.0f);

    g.setColour (kCyan.withAlpha (0.35f));
    g.fillEllipse (pos - 10.0f, cy - 10.0f, 20.0f, 20.0f);
    g.setColour (kCream);
    g.fillEllipse (pos - 6.5f, cy - 6.5f, 13.0f, 13.0f);
}

void SoftLNF::drawComboBox (juce::Graphics& g, int w, int h, bool,
                            int, int, int, int, juce::ComboBox&)
{
    auto r = juce::Rectangle<float> (0, 0, (float) w, (float) h).reduced (1.0f);
    g.setColour (juce::Colour (0x33121826));
    g.fillRoundedRectangle (r, h * 0.5f);
    g.setColour (kChrome.withAlpha (0.18f));
    g.drawRoundedRectangle (r, h * 0.5f, 1.0f);
    juce::Path p;
    const float cx = (float) w - 14.0f, cy = (float) h * 0.5f;
    p.addTriangle (cx - 4, cy - 2, cx + 4, cy - 2, cx, cy + 3);
    g.setColour (kCyan.withAlpha (0.8f));
    g.fillPath (p);
}

void SoftLNF::positionComboBoxText (juce::ComboBox& box, juce::Label& label)
{
    label.setBounds (12, 0, box.getWidth() - 28, box.getHeight());
    label.setFont (softFont (12.0f));
    label.setColour (juce::Label::textColourId, kCream);
    label.setJustificationType (juce::Justification::centredLeft);
}

void SoftLNF::drawToggleButton (juce::Graphics& g, juce::ToggleButton& b,
                                bool /*over*/, bool /*down*/)
{
    auto r = b.getLocalBounds().toFloat().reduced (1.0f);
    auto pill = r.removeFromLeft (juce::jmin (40.0f, r.getWidth()));
    pill = pill.withSizeKeepingCentre (34.0f, 18.0f);
    const bool on = b.getToggleState();

    g.setColour (on ? kCyan.withAlpha (0.28f) : juce::Colour (0x33121826));
    g.fillRoundedRectangle (pill, pill.getHeight() * 0.5f);
    g.setColour ((on ? kCyan : kChrome).withAlpha (0.4f));
    g.drawRoundedRectangle (pill, pill.getHeight() * 0.5f, 1.0f);

    const float knobD = pill.getHeight() - 5.0f;
    const float kx = on ? pill.getRight() - knobD - 2.5f : pill.getX() + 2.5f;
    if (on) { g.setColour (kCyan.withAlpha (0.35f)); g.fillEllipse (kx - 2, pill.getY() + 0.5f, knobD + 4, knobD + 4); }
    g.setColour (on ? kCream : kChrome.withAlpha (0.8f));
    g.fillEllipse (kx, pill.getY() + 2.5f, knobD, knobD);

    g.setColour (kCream.withAlpha (on ? 0.95f : 0.7f));
    g.setFont (softFont (11.0f));
    g.drawText (b.getButtonText(), r.withTrimmedLeft (6.0f), juce::Justification::centredLeft);
}

void SoftLNF::drawPopupMenuBackground (juce::Graphics& g, int w, int h)
{
    g.setColour (juce::Colour (0xef0a0e16));
    g.fillRoundedRectangle (0, 0, (float) w, (float) h, 10.0f);
    g.setColour (kChrome.withAlpha (0.15f));
    g.drawRoundedRectangle (0.5f, 0.5f, (float) w - 1, (float) h - 1, 10.0f, 1.0f);
}

// ============================================================================
ResonanceAudioProcessorEditor::ResonanceAudioProcessorEditor (ResonanceAudioProcessor& p)
    : juce::AudioProcessorEditor (p), proc (p), eqComp (p)
{
    setLookAndFeel (&lnf);
    setSize (820, 584);

    addAndMakeVisible (eqComp);
    eqComp.onSelectBand = [this] (int band) { bindBand (band); };

    // instrument presets bar
    instrumentL.setText ("INSTRUMENT", juce::dontSendNotification);
    instrumentL.setFont (softFont (9.5f, "Regular"));
    instrumentL.setColour (juce::Label::textColourId, kChrome.withAlpha (0.7f));
    instrumentL.setJustificationType (juce::Justification::centredRight);
    addAndMakeVisible (instrumentL);

    for (int i = 0; i < kNumInstruments; ++i)
        instrumentBox.addItem (kInstruments[i].name, i + 1);
    const int savedInstrument = (int) proc.apvts.state.getProperty ("instrument", 1);
    instrumentBox.setSelectedId (juce::jlimit (1, kNumInstruments, savedInstrument), juce::dontSendNotification);
    instrumentBox.onChange = [this]
    {
        const int idx = instrumentBox.getSelectedId() - 1;
        if (idx >= 0) applyInstrument (idx);
    };
    addAndMakeVisible (instrumentBox);

    // selected node precision controls
    bandTitle.setFont (softFont (13.0f));
    bandTitle.setColour (juce::Label::textColourId, kCream.withAlpha (0.9f));
    addAndMakeVisible (bandTitle);

    addAndMakeVisible (bandOn);
    bandTypeBox.addItemList ({ "Low Cut", "Low Shelf", "Bell", "High Shelf", "High Cut" }, 1);
    addAndMakeVisible (bandTypeBox);

    styleKnob (bandFreq);
    styleKnob (bandQ);
    addLabel (freqL, "FREQ");
    addLabel (qL, "Q");

    bandGain.setSliderStyle (juce::Slider::LinearHorizontal);
    bandGain.setTextBoxStyle (juce::Slider::TextBoxRight, false, 64, 18);
    bandGain.setColour (juce::Slider::textBoxTextColourId, kCream.withAlpha (0.9f));
    bandGain.setColour (juce::Slider::textBoxOutlineColourId, juce::Colours::transparentBlack);
    bandGain.setMouseDragSensitivity (620);
    bandGain.setDoubleClickReturnValue (true, 0.0);
    bandGain.setTextValueSuffix (" dB");
    addAndMakeVisible (bandGain);
    addLabel (gainL, "GAIN · PRECISION FADER");

    // logic row
    masterLogicBox.addItemList ({ "Off", "Resonance v2", "CLEAR", "Unified Hybrid v1" }, 1);
    mixLogicBox.addItemList ({ "Off", "Glue Bus", "Warm Tape", "Wide & Open", "Vocal Forward", "Low-End Lock" }, 1);
    addAndMakeVisible (masterLogicBox);
    addAndMakeVisible (mixLogicBox);

    styleKnob (amount); styleKnob (trim); styleKnob (ceiling); styleKnob (mix); styleKnob (outGain);
    addLabel (amountL, "AMOUNT"); addLabel (trimL, "TRIM"); addLabel (ceilL, "CEIL");
    addLabel (mixL, "MIX"); addLabel (outL, "OUT");

    readout.setJustificationType (juce::Justification::centred);
    readout.setColour (juce::Label::textColourId, kCream.withAlpha (0.8f));
    readout.setFont (softFont (12.0f, "Regular"));
    addAndMakeVisible (readout);

    auto& s = proc.apvts;
    masterLogicAtt = std::make_unique<CA> (s, "masterLogic", masterLogicBox);
    mixLogicAtt    = std::make_unique<CA> (s, "mixLogic", mixLogicBox);
    amountAtt      = std::make_unique<SA> (s, "amount", amount);
    trimAtt        = std::make_unique<SA> (s, "trim", trim);
    ceilAtt        = std::make_unique<SA> (s, "ceil", ceiling);
    mixAtt         = std::make_unique<SA> (s, "mix", mix);
    outAtt         = std::make_unique<SA> (s, "out", outGain);

    bindBand (eqComp.getSelectedBand());
    startTimerHz (30);
}

ResonanceAudioProcessorEditor::~ResonanceAudioProcessorEditor() { setLookAndFeel (nullptr); }

void ResonanceAudioProcessorEditor::styleKnob (juce::Slider& sl)
{
    sl.setSliderStyle (juce::Slider::RotaryHorizontalVerticalDrag);
    sl.setTextBoxStyle (juce::Slider::TextBoxBelow, false, 58, 15);
    sl.setColour (juce::Slider::textBoxTextColourId, kCream.withAlpha (0.85f));
    sl.setColour (juce::Slider::textBoxOutlineColourId, juce::Colours::transparentBlack);
    addAndMakeVisible (sl);
}

void ResonanceAudioProcessorEditor::addLabel (juce::Label& l, const juce::String& t)
{
    l.setText (t, juce::dontSendNotification);
    l.setJustificationType (juce::Justification::centred);
    l.setFont (softFont (9.5f, "Regular"));
    l.setColour (juce::Label::textColourId, kChrome.withAlpha (0.7f));
    addAndMakeVisible (l);
}

void ResonanceAudioProcessorEditor::bindBand (int band)
{
    bandOnAtt.reset(); bandTypeAtt.reset();
    bandFreqAtt.reset(); bandQAtt.reset(); bandGainAtt.reset();

    auto& s = proc.apvts;
    bandOnAtt   = std::make_unique<BA> (s, ResonanceAudioProcessor::bandParamID (band, "on"), bandOn);
    bandTypeAtt = std::make_unique<CA> (s, ResonanceAudioProcessor::bandParamID (band, "type"), bandTypeBox);
    bandFreqAtt = std::make_unique<SA> (s, ResonanceAudioProcessor::bandParamID (band, "freq"), bandFreq);
    bandQAtt    = std::make_unique<SA> (s, ResonanceAudioProcessor::bandParamID (band, "q"), bandQ);
    bandGainAtt = std::make_unique<SA> (s, ResonanceAudioProcessor::bandParamID (band, "gain"), bandGain);

    bandTitle.setText ("NODE " + juce::String (band + 1), juce::dontSendNotification);
}

void ResonanceAudioProcessorEditor::applyInstrument (int presetIndex)
{
    const auto& preset = kInstruments[presetIndex];
    auto& s = proc.apvts;

    auto setValue = [&s] (const juce::String& id, float value)
    {
        if (auto* param = s.getParameter (id))
        {
            param->beginChangeGesture();
            param->setValueNotifyingHost (param->convertTo0to1 (value));
            param->endChangeGesture();
        }
    };

    for (int b = 0; b < ResonanceEngine::kNumBands; ++b)
    {
        if (b < 4)
        {
            const auto& bs = preset.bands[b];
            setValue (ResonanceAudioProcessor::bandParamID (b, "on"),   1.0f);
            setValue (ResonanceAudioProcessor::bandParamID (b, "type"), (float) bs.type);
            setValue (ResonanceAudioProcessor::bandParamID (b, "freq"), bs.freq);
            setValue (ResonanceAudioProcessor::bandParamID (b, "gain"), bs.gain);
            setValue (ResonanceAudioProcessor::bandParamID (b, "q"),    bs.q);
        }
        else
        {
            setValue (ResonanceAudioProcessor::bandParamID (b, "on"), 0.0f);
        }
    }

    proc.apvts.state.setProperty ("instrument", presetIndex + 1, nullptr);
    eqComp.setSelectedBand (juce::jmin (eqComp.getSelectedBand(), 3));
}

void ResonanceAudioProcessorEditor::paint (juce::Graphics& g)
{
    auto bounds = getLocalBounds().toFloat();
    g.fillAll (kNavy);

    // soft dark wash so the glass reads
    juce::ColourGradient wash (juce::Colour (0x400a0e16), bounds.getCentreX(), 0.0f,
                               juce::Colour (0xc00a0e16), bounds.getCentreX(), bounds.getBottom(), false);
    g.setGradientFill (wash);
    g.fillRect (bounds);

    // faint cyan bloom behind the title
    juce::ColourGradient bloom (kCyan.withAlpha (0.08f), 180.0f, 40.0f,
                                kCyan.withAlpha (0.0f), 560.0f, 220.0f, true);
    g.setGradientFill (bloom);
    g.fillRect (bounds);

    glassPanel (g, panelGraph.toFloat());
    glassPanel (g, panelPresets.toFloat(), 14.0f);
    glassPanel (g, panelNode.toFloat());
    glassPanel (g, panelLogic.toFloat());

    g.setFont (softFont (56.0f, "Medium"));
    drawGlowText (g, "resonance", { 24, 8, 500, 62 }, juce::Justification::topLeft, kCream, 1.6f);
    g.setFont (softFont (13.0f, "Regular"));
    g.setColour (kChrome.withAlpha (0.7f));
    g.drawText ("instrument eq  ·  mix logic  ·  master logic — the desktop chain, live in the DAW",
                28, 62, 620, 18, juce::Justification::topLeft);
}

void ResonanceAudioProcessorEditor::resized()
{
    auto r = getLocalBounds().reduced (16);
    r.removeFromTop (74); // title

    panelGraph = r.removeFromTop (196);
    eqComp.setBounds (panelGraph.reduced (12));
    r.removeFromTop (8);

    panelPresets = r.removeFromTop (34);
    {
        auto row = panelPresets.reduced (10, 5);
        instrumentL.setBounds (row.removeFromLeft (86));
        row.removeFromLeft (8);
        instrumentBox.setBounds (row.removeFromLeft (210).reduced (0, 1));
    }
    r.removeFromTop (8);

    const int rowH = 100;

    panelNode = r.removeFromTop (rowH);
    {
        auto inner = panelNode.reduced (14, 10);
        auto left = inner.removeFromLeft (128);
        bandTitle.setBounds (left.removeFromTop (20));
        bandOn.setBounds (left.removeFromTop (24));
        bandTypeBox.setBounds (left.removeFromTop (22).reduced (0, 1));

        auto freqCell = inner.removeFromLeft (92);
        freqL.setBounds (freqCell.removeFromTop (13));
        bandFreq.setBounds (freqCell.reduced (3, 0));

        auto qCell = inner.removeFromLeft (92);
        qL.setBounds (qCell.removeFromTop (13));
        bandQ.setBounds (qCell.reduced (3, 0));

        inner.removeFromLeft (10);
        gainL.setBounds (inner.removeFromTop (13));
        bandGain.setBounds (inner.reduced (6, 14));
    }
    r.removeFromTop (8);

    panelLogic = r.removeFromTop (rowH);
    {
        auto inner = panelLogic.reduced (14, 10);
        auto left = inner.removeFromLeft (168);
        left.removeFromTop (8);
        masterLogicBox.setBounds (left.removeFromTop (24).reduced (0, 1));
        left.removeFromTop (8);
        mixLogicBox.setBounds (left.removeFromTop (24).reduced (0, 1));
        inner.removeFromLeft (10);

        const int nk = 5;
        const int kw = inner.getWidth() / nk;
        auto place = [&inner, kw] (juce::Slider& sl, juce::Label& lb)
        {
            auto cell = inner.removeFromLeft (kw);
            lb.setBounds (cell.removeFromTop (13));
            sl.setBounds (cell.reduced (3, 0));
        };
        place (amount, amountL);
        place (trim, trimL);
        place (ceiling, ceilL);
        place (mix, mixL);
        place (outGain, outL);
    }

    readout.setBounds (getLocalBounds().removeFromBottom (24));
}

void ResonanceAudioProcessorEditor::timerCallback()
{
    eqComp.refreshIfChanged();

    const int band = eqComp.getSelectedBand();
    const auto typeName = bandTypeBox.getText();
    const float freq = bandFreq.getValue() >= 1000.0
                     ? (float) bandFreq.getValue() / 1000.0f : (float) bandFreq.getValue();
    const juce::String freqUnit = bandFreq.getValue() >= 1000.0 ? " kHz" : " Hz";
    const double latencyMs = proc.getLatencySamples() * 1000.0
                           / (proc.getSampleRate() > 0 ? proc.getSampleRate() : 48000.0);

    readout.setText (
        juce::String::formatted ("node %d · %s · %.1f%s · %+.2f dB · q %.2f      |      %s + %s      |      latency %.1f ms",
            band + 1,
            typeName.toRawUTF8(),
            freq, freqUnit.toRawUTF8(),
            bandGain.getValue(),
            bandQ.getValue(),
            masterLogicBox.getText().toRawUTF8(),
            mixLogicBox.getText().toRawUTF8(),
            latencyMs),
        juce::dontSendNotification);
}
