#include "PluginProcessor.h"
#include "PluginEditor.h"

namespace
{
    struct BandDefault { bool on; int type; float freq, gain, q; };

    constexpr BandDefault kBandDefaults[ResonanceEngine::kNumBands] = {
        { true,  ResonanceEngine::LowShelf,     90.0f, 0.0f, 0.71f },
        { true,  ResonanceEngine::Bell,        250.0f, 0.0f, 1.00f },
        { true,  ResonanceEngine::Bell,       3000.0f, 0.0f, 1.00f },
        { true,  ResonanceEngine::HighShelf, 10000.0f, 0.0f, 0.71f },
        { false, ResonanceEngine::Bell,        500.0f, 0.0f, 1.00f },
        { false, ResonanceEngine::Bell,       1500.0f, 0.0f, 1.00f },
        { false, ResonanceEngine::Bell,       6000.0f, 0.0f, 1.00f },
        { false, ResonanceEngine::Bell,      12000.0f, 0.0f, 1.00f },
    };
}

ResonanceAudioProcessor::ResonanceAudioProcessor()
    : juce::AudioProcessor (BusesProperties()
        .withInput ("Input", juce::AudioChannelSet::stereo(), true)
        .withOutput ("Output", juce::AudioChannelSet::stereo(), true)),
      apvts (*this, nullptr, "PARAMS", createLayout())
{
    pTrim   = apvts.getRawParameterValue ("trim");
    pOut    = apvts.getRawParameterValue ("out");
    pMix    = apvts.getRawParameterValue ("mix");
    pCeil   = apvts.getRawParameterValue ("ceil");
    pAmount = apvts.getRawParameterValue ("amount");
    pMasterLogic = apvts.getRawParameterValue ("masterLogic");
    pMixLogic    = apvts.getRawParameterValue ("mixLogic");

    for (int i = 0; i < ResonanceEngine::kNumBands; ++i)
    {
        pOn[i]   = apvts.getRawParameterValue (bandParamID (i, "on"));
        pType[i] = apvts.getRawParameterValue (bandParamID (i, "type"));
        pFreq[i] = apvts.getRawParameterValue (bandParamID (i, "freq"));
        pGain[i] = apvts.getRawParameterValue (bandParamID (i, "gain"));
        pQ[i]    = apvts.getRawParameterValue (bandParamID (i, "q"));
    }
}

juce::AudioProcessorValueTreeState::ParameterLayout ResonanceAudioProcessor::createLayout()
{
    using namespace juce;
    AudioProcessorValueTreeState::ParameterLayout p;

    p.add (std::make_unique<AudioParameterChoice> (ParameterID { "masterLogic", 1 }, "Master Logic",
        StringArray { "Off", "Resonance v2", "CLEAR", "Unified Hybrid v1" }, 1));

    p.add (std::make_unique<AudioParameterChoice> (ParameterID { "mixLogic", 1 }, "Mix Logic",
        StringArray { "Off", "Glue Bus", "Warm Tape", "Wide & Open", "Vocal Forward", "Low-End Lock" }, 0));

    p.add (std::make_unique<AudioParameterFloat> (ParameterID { "amount", 1 }, "Amount",
        NormalisableRange<float> (0.0f, 1.0f, 0.01f), 0.7f));

    p.add (std::make_unique<AudioParameterFloat> (ParameterID { "trim", 1 }, "Input Trim",
        NormalisableRange<float> (-12.0f, 12.0f, 0.1f), 0.0f));

    p.add (std::make_unique<AudioParameterFloat> (ParameterID { "ceil", 1 }, "Ceiling",
        NormalisableRange<float> (-3.0f, 0.0f, 0.1f), -1.0f));

    p.add (std::make_unique<AudioParameterFloat> (ParameterID { "mix", 1 }, "Mix",
        NormalisableRange<float> (0.0f, 1.0f, 0.01f), 1.0f));

    p.add (std::make_unique<AudioParameterFloat> (ParameterID { "out", 1 }, "Output Gain",
        NormalisableRange<float> (-24.0f, 12.0f, 0.1f), 0.0f));

    const StringArray typeNames { "Low Cut", "Low Shelf", "Bell", "High Shelf", "High Cut" };

    for (int i = 0; i < ResonanceEngine::kNumBands; ++i)
    {
        const auto& d = kBandDefaults[i];
        const auto num = String (i + 1);

        p.add (std::make_unique<AudioParameterBool> (ParameterID { bandParamID (i, "on"), 1 },
            "EQ " + num + " On", d.on));

        p.add (std::make_unique<AudioParameterChoice> (ParameterID { bandParamID (i, "type"), 1 },
            "EQ " + num + " Type", typeNames, d.type));

        NormalisableRange<float> freqRange (20.0f, 20000.0f, 0.01f);
        freqRange.setSkewForCentre (632.0f);
        p.add (std::make_unique<AudioParameterFloat> (ParameterID { bandParamID (i, "freq"), 1 },
            "EQ " + num + " Freq", freqRange, d.freq));

        p.add (std::make_unique<AudioParameterFloat> (ParameterID { bandParamID (i, "gain"), 1 },
            "EQ " + num + " Gain", NormalisableRange<float> (-18.0f, 18.0f, 0.01f), d.gain));

        NormalisableRange<float> qRange (0.1f, 10.0f, 0.01f);
        qRange.setSkewForCentre (1.0f);
        p.add (std::make_unique<AudioParameterFloat> (ParameterID { bandParamID (i, "q"), 1 },
            "EQ " + num + " Q", qRange, d.q));
    }

    return p;
}

ResonanceEngine::Params ResonanceAudioProcessor::gatherParams() const
{
    ResonanceEngine::Params ep;
    ep.trimDb      = *pTrim;
    ep.outDb       = *pOut;
    ep.mix         = *pMix;
    ep.ceilingDb   = *pCeil;
    ep.amount      = *pAmount;
    ep.masterLogic = (int) *pMasterLogic;
    ep.mixLogic    = (int) *pMixLogic;

    for (int i = 0; i < ResonanceEngine::kNumBands; ++i)
    {
        ep.bands[i].on     = *pOn[i] > 0.5f;
        ep.bands[i].type   = (int) *pType[i];
        ep.bands[i].freq   = *pFreq[i];
        ep.bands[i].gainDb = *pGain[i];
        ep.bands[i].q      = *pQ[i];
    }
    return ep;
}

void ResonanceAudioProcessor::prepareToPlay (double sr, int samples)
{
    engine.setParams (gatherParams());
    engine.prepare (sr, samples, juce::jmax (2, getTotalNumOutputChannels()));
    setLatencySamples (engine.latencySamples());
}

bool ResonanceAudioProcessor::isBusesLayoutSupported (const BusesLayout& layouts) const
{
    const auto& out = layouts.getMainOutputChannelSet();
    if (out != juce::AudioChannelSet::mono() && out != juce::AudioChannelSet::stereo())
        return false;
    return layouts.getMainInputChannelSet() == out;
}

void ResonanceAudioProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer&)
{
    juce::ScopedNoDenormals noDenormals;
    if (buffer.getNumSamples() == 0 || buffer.getNumChannels() == 0)
        return;

    engine.setParams (gatherParams());
    engine.process (buffer);
}

juce::AudioProcessorEditor* ResonanceAudioProcessor::createEditor()
{
    return new ResonanceAudioProcessorEditor (*this);
}

void ResonanceAudioProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto xml = apvts.copyState().createXml())
        copyXmlToBinary (*xml, dest);
}

void ResonanceAudioProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter()
{
    return new ResonanceAudioProcessor();
}
