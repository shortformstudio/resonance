#pragma once
#include <juce_dsp/juce_dsp.h>
#include <juce_audio_processors/juce_audio_processors.h>
#include <cmath>

// Real-time engine: 8-band node EQ -> mix logic -> master logic -> dry/wet -> out -> lookahead limiter.
// Coefficients redesign only when a parameter changes; limiter state persists across blocks.
class ResonanceEngine
{
public:
    static constexpr int kNumBands = 8;

    enum BandType    { LowCut = 0, LowShelf, Bell, HighShelf, HighCut };
    enum MasterLogic { MasterOff = 0, MasterV2, MasterClear, MasterV1 };
    enum MixLogic    { MixOff = 0, MixGlueBus, MixWarmTape, MixWideOpen, MixVocalForward, MixLowEndLock };

    struct BandParams
    {
        bool  on     = false;
        int   type   = Bell;
        float freq   = 1000.0f;
        float gainDb = 0.0f;
        float q      = 1.0f;

        bool operator!= (const BandParams& o) const noexcept
        {
            return on != o.on || type != o.type || freq != o.freq
                || gainDb != o.gainDb || q != o.q;
        }
    };

    struct Params
    {
        float trimDb    = 0.0f;
        float outDb     = 0.0f;
        float mix       = 1.0f;
        float ceilingDb = -1.0f;
        float amount    = 0.7f;
        int   masterLogic = MasterV2;
        int   mixLogic    = MixOff;
        BandParams bands[kNumBands];
    };

    void prepare (double sampleRate, int blockSize, int numChannels);
    void reset();
    void setParams (const Params& p);          // audio thread; cheap compare + targeted redesign
    void process (juce::AudioBuffer<float>& buffer);
    int  latencySamples() const noexcept       { return limiter.lookahead; }

private:
    static constexpr int maxCh = 2;

    struct Biquad
    {
        float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
        float x1[maxCh] = {}, x2[maxCh] = {}, y1[maxCh] = {}, y2[maxCh] = {};

        void set (const juce::dsp::IIR::Coefficients<float>& c) noexcept
        {
            b0 = c.coefficients[0]; b1 = c.coefficients[1]; b2 = c.coefficients[2];
            a1 = c.coefficients[3]; a2 = c.coefficients[4];
        }
        void clearState() noexcept
        {
            for (int ch = 0; ch < maxCh; ++ch) { x1[ch] = x2[ch] = y1[ch] = y2[ch] = 0.0f; }
        }
        float process (int ch, float x) noexcept
        {
            const float y = b0 * x + b1 * x1[ch] + b2 * x2[ch] - a1 * y1[ch] - a2 * y2[ch];
            x2[ch] = x1[ch]; x1[ch] = x;
            y2[ch] = y1[ch]; y1[ch] = y;
            return y;
        }
    };

    struct OnePole
    {
        float z[maxCh] = {};
        float a = 0.0f;
        void setCutoff (float hz, double sr) noexcept { a = std::exp (float (-juce::MathConstants<double>::twoPi * hz / sr)); }
        void clearState() noexcept { z[0] = z[1] = 0.0f; }
        float low (int ch, float x) noexcept { z[ch] = (1.0f - a) * x + a * z[ch]; return z[ch]; }
    };

    struct ADAATanh
    {
        float gain = 1.0f;
        float x1[maxCh] = {}, f1[maxCh] = {};
        void clearState() noexcept { for (int ch = 0; ch < maxCh; ++ch) { x1[ch] = 0; f1[ch] = 0; } }
        float antideriv (float x) const noexcept
        {
            const float gx = std::abs (gain * x);
            const float lnCosh = gx > 20.0f ? gx - 0.6931471805599453f : std::log (std::cosh (gx));
            return lnCosh / gain;
        }
        float process (int ch, float x) noexcept
        {
            const float f  = antideriv (x);
            const float dx = x - x1[ch];
            const float y  = std::abs (dx) < 1.0e-9f
                           ? std::tanh (gain * 0.5f * (x + x1[ch]))
                           : (f - f1[ch]) / dx;
            x1[ch] = x; f1[ch] = f;
            return y;
        }
    };

    struct Compressor
    {
        double env = 0.0;
        double aAtt = 0.0, aRel = 0.0;
        float  thresholdDb = -20.0f, slope = 0.0f, kneeDb = 6.0f;
        float  blend = 1.0f;

        void configure (float thrDb, float ratio, float attMs, float relMs, double sr, float blendAmt) noexcept
        {
            thresholdDb = thrDb;
            slope       = 1.0f / ratio - 1.0f;
            aAtt        = std::exp (-1.0 / (attMs * 0.001 * sr));
            aRel        = std::exp (-1.0 / (relMs * 0.001 * sr));
            blend       = blendAmt;
        }
        void clearState() noexcept { env = 0.0; }
        float gainFor (float meanSquare) noexcept
        {
            const double coeff = meanSquare > env ? aAtt : aRel;
            env = meanSquare + coeff * (env - meanSquare);
            const double levelDb = 10.0 * std::log10 (std::max (env, 1.0e-12));
            const double over = levelDb - thresholdDb;
            const double kneeHalf = kneeDb * 0.5;
            double gDb = 0.0;
            if (over >= kneeHalf)       gDb = slope * over;
            else if (over > -kneeHalf)  { const double t = over + kneeHalf; gDb = slope * t * t / (2.0 * kneeDb); }
            const float g = (float) std::pow (10.0, gDb / 20.0);
            return 1.0f + (g - 1.0f) * blend;
        }
    };

    struct Limiter
    {
        juce::AudioBuffer<float> delay;
        int   size = 0, write = 0, lookahead = 0;
        float env = 1.0f, aAtt = 0.0f, aRel = 0.0f, threshold = 1.0f;

        void prepare (double sr)
        {
            lookahead = juce::jmax (1, (int) (0.002 * sr));
            size      = lookahead + 1;
            delay.setSize (maxCh, size);
            aAtt = std::exp (float (-1.0 / (0.0007 * sr)));
            aRel = std::exp (float (-1.0 / (0.100  * sr)));
            clearState();
        }
        void setCeiling (float db) noexcept { threshold = std::pow (10.0f, db / 20.0f) * 0.995f; }
        void clearState() { delay.clear(); write = 0; env = 1.0f; }

        // Push the newest stereo sample, return the delayed, gain-ridden pair.
        void process (float inL, float inR, float& outL, float& outR, int numCh) noexcept
        {
            delay.setSample (0, write, inL);
            if (maxCh > 1) delay.setSample (1, write, numCh > 1 ? inR : inL);

            const int read = (write + 1) % size;   // oldest sample = lookahead delay
            write = read;

            const float peak = juce::jmax (std::abs (inL), numCh > 1 ? std::abs (inR) : 0.0f);
            const float target = peak > threshold ? threshold / peak : 1.0f;
            const float coeff  = target < env ? aAtt : aRel;
            env = target + coeff * (env - target);
            const float g = juce::jmin (env, 1.0f);

            outL = juce::jlimit (-threshold, threshold, delay.getSample (0, read) * g);
            outR = juce::jlimit (-threshold, threshold, delay.getSample (juce::jmin (1, maxCh - 1), read) * g);
        }
    };

    void designBand (int index);
    void designMasterChain (bool logicChanged);
    void designMixChain (bool logicChanged);

    double sampleRate = 44100.0;
    int    numChannels = 2;

    Params cur;
    bool   primed = false;

    // node EQ
    Biquad eqBands[kNumBands];

    // master logic blocks
    Biquad mMud, mSideHP, mHpfA, mHpfB, mLowShelf, mAir;
    OnePole mSubSplit, mSideSplit;
    ADAATanh mSat;
    Compressor mComp;
    float mWidthGain = 1.0f;
    float mDriveDb   = 0.0f;

    // mix logic blocks
    Biquad xA, xB, xC, xSideHP;
    OnePole xSubSplit;
    ADAATanh xSat;
    Compressor xComp;
    float xWidthGain = 1.0f;

    Limiter limiter;

    juce::AudioBuffer<float> dryBuf;
    juce::SmoothedValue<float> smIn { 1.0f }, smOut { 1.0f }, smMix { 1.0f };
};
