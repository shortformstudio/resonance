#pragma once
#include <juce_audio_processors/juce_audio_processors.h>
#include "ResonanceEngine.h"

class ResonanceAudioProcessor : public juce::AudioProcessor
{
public:
    ResonanceAudioProcessor();
    ~ResonanceAudioProcessor() override = default;

    void prepareToPlay (double sampleRate, int samplesPerBlock) override;
    void releaseResources() override {}
    bool isBusesLayoutSupported (const BusesLayout&) const override;
    void processBlock (juce::AudioBuffer<float>&, juce::MidiBuffer&) override;

    juce::AudioProcessorEditor* createEditor() override;
    bool hasEditor() const override                    { return true; }
    const juce::String getName() const override        { return "Resonance"; }
    bool acceptsMidi() const override                  { return false; }
    bool producesMidi() const override                 { return false; }
    bool isMidiEffect() const override                 { return false; }
    double getTailLengthSeconds() const override       { return 0.0; }
    int getNumPrograms() override                      { return 1; }
    int getCurrentProgram() override                   { return 0; }
    void setCurrentProgram (int) override              {}
    const juce::String getProgramName (int) override   { return {}; }
    void changeProgramName (int, const juce::String&) override {}
    void getStateInformation (juce::MemoryBlock&) override;
    void setStateInformation (const void*, int) override;

    juce::AudioProcessorValueTreeState apvts;

    static juce::String bandParamID (int band, const char* suffix)
    {
        return "eq" + juce::String (band + 1) + suffix;
    }

private:
    ResonanceEngine engine;

    juce::AudioProcessorValueTreeState::ParameterLayout createLayout();
    ResonanceEngine::Params gatherParams() const;

    std::atomic<float>* pTrim   = nullptr;
    std::atomic<float>* pOut    = nullptr;
    std::atomic<float>* pMix    = nullptr;
    std::atomic<float>* pCeil   = nullptr;
    std::atomic<float>* pAmount = nullptr;
    std::atomic<float>* pMasterLogic = nullptr;
    std::atomic<float>* pMixLogic    = nullptr;

    std::atomic<float>* pOn[ResonanceEngine::kNumBands]   = {};
    std::atomic<float>* pType[ResonanceEngine::kNumBands] = {};
    std::atomic<float>* pFreq[ResonanceEngine::kNumBands] = {};
    std::atomic<float>* pGain[ResonanceEngine::kNumBands] = {};
    std::atomic<float>* pQ[ResonanceEngine::kNumBands]    = {};

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (ResonanceAudioProcessor)
};
