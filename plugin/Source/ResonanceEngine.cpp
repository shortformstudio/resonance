#include "ResonanceEngine.h"

using Coeffs = juce::dsp::IIR::Coefficients<float>;

void ResonanceEngine::prepare (double sr, int blockSize, int numCh)
{
    sampleRate  = sr;
    numChannels = juce::jmin (numCh, maxCh);

    mSubSplit.setCutoff (150.0f, sr);
    mSideSplit.setCutoff (120.0f, sr);
    xSubSplit.setCutoff (150.0f, sr);

    limiter.prepare (sr);
    limiter.setCeiling (cur.ceilingDb);

    dryBuf.setSize (maxCh, juce::jmax (blockSize, 16));

    smIn.reset (sr, 0.03);  smIn.setCurrentAndTargetValue (juce::Decibels::decibelsToGain (cur.trimDb));
    smOut.reset (sr, 0.03); smOut.setCurrentAndTargetValue (juce::Decibels::decibelsToGain (cur.outDb));
    smMix.reset (sr, 0.03); smMix.setCurrentAndTargetValue (cur.mix);

    for (int i = 0; i < kNumBands; ++i) designBand (i);
    designMasterChain (true);
    designMixChain (true);

    reset();
    primed = true;
}

void ResonanceEngine::reset()
{
    for (auto* bq : { &mMud, &mSideHP, &mHpfA, &mHpfB, &mLowShelf, &mAir, &xA, &xB, &xC, &xSideHP })
        bq->clearState();
    for (int i = 0; i < kNumBands; ++i) eqBands[i].clearState();
    mSubSplit.clearState(); mSideSplit.clearState(); xSubSplit.clearState();
    mSat.clearState(); xSat.clearState();
    mComp.clearState(); xComp.clearState();
    limiter.clearState();
}

void ResonanceEngine::designBand (int i)
{
    const auto& b = cur.bands[i];
    const float nyq  = (float) (sampleRate * 0.45);
    const float f    = juce::jlimit (20.0f, juce::jmin (20000.0f, nyq), b.freq);
    const float q    = juce::jlimit (0.05f, 18.0f, b.q);
    const float gain = juce::Decibels::decibelsToGain (juce::jlimit (-24.0f, 24.0f, b.gainDb));

    Coeffs::Ptr c;
    switch (b.type)
    {
        case LowCut:    c = Coeffs::makeHighPass  (sampleRate, f, q);        break;
        case LowShelf:  c = Coeffs::makeLowShelf  (sampleRate, f, q, gain);  break;
        case HighShelf: c = Coeffs::makeHighShelf (sampleRate, f, q, gain);  break;
        case HighCut:   c = Coeffs::makeLowPass   (sampleRate, f, q);        break;
        case Bell: default: c = Coeffs::makePeakFilter (sampleRate, f, q, gain); break;
    }
    eqBands[i].set (*c);
}

void ResonanceEngine::designMasterChain (bool logicChanged)
{
    const float amt = cur.amount;

    switch (cur.masterLogic)
    {
        case MasterV2:
            mMud.set    (*Coeffs::makePeakFilter (sampleRate, 420.0f, 0.4f, juce::Decibels::decibelsToGain (-2.5f * amt)));
            mSideHP.set (*Coeffs::makeHighPass   (sampleRate, 120.0f, 0.707f));
            mWidthGain = 1.0f + 0.12f * amt;
            mDriveDb   = 1.5f * amt;
            mComp.configure (-22.0f, 1.5f, 50.0f, 200.0f, sampleRate, amt);
            break;

        case MasterClear:
        {
            auto hp = Coeffs::makeHighPass (sampleRate, 40.0f, 0.707f);
            mHpfA.set (*hp); mHpfB.set (*hp);
            mLowShelf.set (*Coeffs::makeLowShelf   (sampleRate, 180.0f,   0.7f, juce::Decibels::decibelsToGain (-3.5f * amt)));
            mMud.set      (*Coeffs::makePeakFilter (sampleRate, 450.0f,   0.5f, juce::Decibels::decibelsToGain (-2.0f * amt)));
            mAir.set      (*Coeffs::makeHighShelf  (sampleRate, 12000.0f, 0.7f, juce::Decibels::decibelsToGain ( 3.0f * amt)));
            mDriveDb = 0.0f;
            mComp.configure (-18.0f, 1.15f, 60.0f, 250.0f, sampleRate, amt);
            break;
        }

        case MasterV1:
            mHpfA.set (*Coeffs::makeHighPass   (sampleRate, 35.0f, 0.7071f));
            mMud.set  (*Coeffs::makePeakFilter (sampleRate, 420.0f, 0.4f, juce::Decibels::decibelsToGain (-2.5f * amt)));
            mAir.set  (*Coeffs::makeHighShelf  (sampleRate, 12000.0f, 0.707f, juce::Decibels::decibelsToGain (2.0f * amt)));
            mDriveDb = 1.2f * amt;
            mComp.configure (-22.0f, 1.5f, 50.0f, 200.0f, sampleRate, amt);
            break;

        default: break;
    }

    if (logicChanged)
    {
        for (auto* bq : { &mMud, &mSideHP, &mHpfA, &mHpfB, &mLowShelf, &mAir }) bq->clearState();
        mSubSplit.clearState(); mSideSplit.clearState();
        mSat.clearState(); mComp.clearState();
    }
}

void ResonanceEngine::designMixChain (bool logicChanged)
{
    switch (cur.mixLogic)
    {
        case MixGlueBus:
            xComp.configure (-20.0f, 1.4f, 30.0f, 150.0f, sampleRate, 1.0f);
            break;

        case MixWarmTape:
            xA.set (*Coeffs::makeLowShelf (sampleRate, 100.0f, 0.71f, juce::Decibels::decibelsToGain (1.0f)));
            xSat.gain = std::pow (10.0f, 2.0f / 20.0f);
            break;

        case MixWideOpen:
            xSideHP.set (*Coeffs::makeHighPass  (sampleRate, 100.0f, 0.707f));
            xA.set      (*Coeffs::makeHighShelf (sampleRate, 12000.0f, 0.71f, juce::Decibels::decibelsToGain (1.5f)));
            xWidthGain = 1.18f;
            break;

        case MixVocalForward:
            xA.set (*Coeffs::makePeakFilter (sampleRate, 3000.0f, 0.8f, juce::Decibels::decibelsToGain ( 2.0f)));
            xB.set (*Coeffs::makePeakFilter (sampleRate,  300.0f, 1.0f, juce::Decibels::decibelsToGain (-1.5f)));
            xC.set (*Coeffs::makePeakFilter (sampleRate, 6500.0f, 2.0f, juce::Decibels::decibelsToGain (-1.0f)));
            break;

        case MixLowEndLock:
            xSideHP.set (*Coeffs::makeHighPass   (sampleRate, 100.0f, 0.707f));
            xA.set      (*Coeffs::makeLowShelf   (sampleRate,  60.0f, 0.71f, juce::Decibels::decibelsToGain (1.5f)));
            xB.set      (*Coeffs::makePeakFilter (sampleRate, 120.0f, 1.0f,  juce::Decibels::decibelsToGain (0.8f)));
            break;

        default: break;
    }

    if (logicChanged)
    {
        for (auto* bq : { &xA, &xB, &xC, &xSideHP }) bq->clearState();
        xSubSplit.clearState(); xSat.clearState(); xComp.clearState();
    }
}

void ResonanceEngine::setParams (const Params& p)
{
    if (! primed) { cur = p; return; }

    for (int i = 0; i < kNumBands; ++i)
    {
        if (cur.bands[i] != p.bands[i])
        {
            const bool wasOff = ! cur.bands[i].on;
            cur.bands[i] = p.bands[i];
            designBand (i);
            if (wasOff && p.bands[i].on) eqBands[i].clearState();
        }
    }

    const bool masterLogicChanged = cur.masterLogic != p.masterLogic;
    const bool amountChanged      = cur.amount != p.amount;
    cur.masterLogic = p.masterLogic;
    cur.amount      = p.amount;
    if (masterLogicChanged || amountChanged) designMasterChain (masterLogicChanged);

    const bool mixLogicChanged = cur.mixLogic != p.mixLogic;
    cur.mixLogic = p.mixLogic;
    if (mixLogicChanged) designMixChain (true);

    if (cur.ceilingDb != p.ceilingDb) { cur.ceilingDb = p.ceilingDb; limiter.setCeiling (p.ceilingDb); }

    if (cur.trimDb != p.trimDb) { cur.trimDb = p.trimDb; smIn.setTargetValue (juce::Decibels::decibelsToGain (p.trimDb)); }
    if (cur.outDb  != p.outDb)  { cur.outDb  = p.outDb;  smOut.setTargetValue (juce::Decibels::decibelsToGain (p.outDb)); }
    if (cur.mix    != p.mix)    { cur.mix    = p.mix;    smMix.setTargetValue (p.mix); }
}

void ResonanceEngine::process (juce::AudioBuffer<float>& buffer)
{
    const int n     = buffer.getNumSamples();
    const int numCh = juce::jmin (buffer.getNumChannels(), maxCh);
    if (n == 0 || numCh == 0) return;

    if (dryBuf.getNumSamples() < n) dryBuf.setSize (maxCh, n, false, false, true);
    for (int ch = 0; ch < numCh; ++ch)
        dryBuf.copyFrom (ch, 0, buffer, ch, 0, n);

    const float satDrive = std::pow (10.0f, mDriveDb / 20.0f);
    mSat.gain = juce::jmax (1.0f, satDrive);

    for (int i = 0; i < n; ++i)
    {
        const float inG = smIn.getNextValue();
        float L = buffer.getSample (0, i) * inG;
        float R = numCh > 1 ? buffer.getSample (1, i) * inG : L;

        // 1) node EQ
        for (int b = 0; b < kNumBands; ++b)
        {
            if (! cur.bands[b].on) continue;
            L = eqBands[b].process (0, L);
            R = eqBands[b].process (1, R);
        }

        // 2) mix logic
        switch (cur.mixLogic)
        {
            case MixGlueBus:
            {
                const float g = xComp.gainFor ((L * L + R * R) * 0.5f);
                L *= g; R *= g;
                break;
            }
            case MixWarmTape:
            {
                L = xA.process (0, L); R = xA.process (1, R);
                const float subL = xSubSplit.low (0, L);
                const float subR = xSubSplit.low (1, R);
                L = subL + xSat.process (0, L - subL);
                R = subR + xSat.process (1, R - subR);
                break;
            }
            case MixWideOpen:
            {
                float mid  = (L + R) * 0.5f;
                float side = (L - R) * 0.5f;
                side = xSideHP.process (0, side) * xWidthGain;
                L = mid + side; R = mid - side;
                L = xA.process (0, L); R = xA.process (1, R);
                break;
            }
            case MixVocalForward:
                L = xA.process (0, L); R = xA.process (1, R);
                L = xB.process (0, L); R = xB.process (1, R);
                L = xC.process (0, L); R = xC.process (1, R);
                break;

            case MixLowEndLock:
            {
                float mid  = (L + R) * 0.5f;
                float side = (L - R) * 0.5f;
                side = xSideHP.process (0, side);
                L = mid + side; R = mid - side;
                L = xA.process (0, L); R = xA.process (1, R);
                L = xB.process (0, L); R = xB.process (1, R);
                break;
            }
            default: break;
        }

        // 3) master logic
        switch (cur.masterLogic)
        {
            case MasterV2:
            {
                float mudL = mMud.process (0, L);
                float mudR = mMud.process (1, R);
                L = mudL; R = mudR;

                float mid  = (L + R) * 0.5f;
                float side = (L - R) * 0.5f;
                const float sideHP  = mSideHP.process (0, side);
                const float sideLow = mSideSplit.low (0, side);
                const float sideHi  = sideHP - sideLow;
                side = sideLow + sideHi * mWidthGain;
                L = mid + side; R = mid - side;

                const float subL  = mSubSplit.low (0, L);
                const float subR  = mSubSplit.low (1, R);
                const float bandL = L - subL;
                const float bandR = R - subR;
                const float shapedL = mSat.process (0, bandL);
                const float shapedR = mSat.process (1, bandR);
                L = subL + bandL + (shapedL - bandL) * cur.amount;
                R = subR + bandR + (shapedR - bandR) * cur.amount;

                const float g = mComp.gainFor ((L * L + R * R) * 0.5f);
                L *= g; R *= g;
                break;
            }
            case MasterClear:
            {
                L = mHpfA.process (0, L); L = mHpfB.process (0, L);
                R = mHpfA.process (1, R); R = mHpfB.process (1, R);
                L = mLowShelf.process (0, L); R = mLowShelf.process (1, R);
                L = mMud.process (0, L);      R = mMud.process (1, R);
                L = mAir.process (0, L);      R = mAir.process (1, R);
                const float g = mComp.gainFor ((L * L + R * R) * 0.5f);
                L *= g; R *= g;
                break;
            }
            case MasterV1:
            {
                L = mHpfA.process (0, L); R = mHpfA.process (1, R);
                const float driveG  = mSat.gain;
                const float norm    = juce::jmax (1.0f, driveG * 0.85f);
                const float shapedL = std::tanh (driveG * L) / norm;
                const float shapedR = std::tanh (driveG * R) / norm;
                L += (shapedL - L) * cur.amount;
                R += (shapedR - R) * cur.amount;
                L = mMud.process (0, L); R = mMud.process (1, R);
                L = mAir.process (0, L); R = mAir.process (1, R);
                const float g = mComp.gainFor ((L * L + R * R) * 0.5f);
                L *= g; R *= g;
                break;
            }
            default: break;
        }

        // 4) dry/wet blend
        const float wet = smMix.getNextValue();
        L = dryBuf.getSample (0, i) * (1.0f - wet) + L * wet;
        R = dryBuf.getSample (juce::jmin (1, numCh - 1), i) * (1.0f - wet) + R * wet;

        // 5) output gain
        const float outG = smOut.getNextValue();
        L *= outG; R *= outG;

        // 6) lookahead limiter (persistent state, reported latency)
        limiter.process (L, R, L, R, numCh);

        buffer.setSample (0, i, L);
        if (numCh > 1) buffer.setSample (1, i, R);
    }
}
