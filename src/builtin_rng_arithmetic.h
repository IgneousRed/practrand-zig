// Local counterparts of affected PractRand 0.96 algorithms (CC0).
// Included inside the adapter namespace after the unchanged vendor headers.
// Preserve private state/walk order; define only invalid products/rotates.
#ifndef PRACTRAND_ZIG_BUILTIN_RNG_ARITHMETIC_H
#define PRACTRAND_ZIG_BUILTIN_RNG_ARITHMETIC_H
template<typename Word> Word defined_rotate(Word value, unsigned bits) {
    const unsigned mask = sizeof(Word) * 8 - 1;
    const unsigned shift = bits & mask;
    return Word((value << shift) | (value >> ((0u - shift) & mask)));
}

// From src/RNGs/other/oddball.cpp: mrsf16.
class Defined_mrsf16 : public RNGs::vRNG16 {
    Uint16 a, b;
public:
    using RNGs::vRNG16::seed;
    Uint16 raw16() override {
        Uint16 old = a;
        a = Uint32(b) * 0xB635u;
        b = Internals::rotate16(b, 10) ^ old;
        return old+a;
    }
    std::string get_name() const override {
        return "mrsf16";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a);
        walker->handle(b);
    }
    void seed(Uint64 s) {
        if (!s) s = (1ull << 32) - 1;
        a = Uint16(s);
        b = Uint16(s >> 16);
        for (int i = 0; i < 16; i++) raw16();
    }
};

// From src/RNGs/other/oddball.cpp: mulcrax16.
class Defined_mulcrax16 : public RNGs::vRNG16 {
    Uint16 a, b, count_low, count_high;
public:
    Uint16 raw16() override {
        Uint16 rv = Uint32(a) * Uint32(count_low);
        a = b ^ count_high;
        b = Internals::rotate16(b, 5) + rv;
        count_low += 2;
        if (count_low == 1) {
            count_high++;
            if (!count_high) count_high = 1;
        }
        return rv;
    }
    std::string get_name() const override {
        return "mulcrax16";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a);
        walker->handle(b);
        walker->handle(count_low);
        walker->handle(count_high);
        count_low |= 1;
        if (!count_high) count_high = 1;
    }
};

// From src/RNGs/other/oddball.cpp: mulcrx16.
class Defined_mulcrx16 : public RNGs::vRNG16 {
    Uint16 a, count_low, count_high;
public:
    Uint16 raw16() override {
        Uint16 rv = a;
        a = Internals::rotate16(Uint16(Uint32(a) * Uint32(count_low)), 6) + count_high;
        count_low += 2;
        if (count_low == 1) {
            count_high++;
            if (!count_high) count_high = 1;
        }
        return rv ^ a;
    }
    std::string get_name() const override {
        return "mulcrx16";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a);
        walker->handle(count_low);
        walker->handle(count_high);
        count_low |= 1;
        if (!count_high) count_high = 1;
    }
};

// From src/RNGs/other/oddball.cpp: multish4x16.
class Defined_multish4x16 : public RNGs::vRNG16 {
    Uint16 a, b, c, d;
public:
    Uint16 raw16() override {
        Uint16 old = a;
        if (!c++) d++;
        a = Uint32(b ^ d) * 0x96b9u + c;
        b = ((b << 5) | (b >> 11)) ^ old;
        return old;
    }
    std::string get_name() const override {
        return "multish4x16";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(c); walker->handle(d);
    }
};

// From src/RNGs/other/oddball.cpp: mwlac_varA.
class Defined_mwlac_varA : public RNGs::vRNG16 {
    // The upstream header's extra d is unused and absent from its state walk.
    Uint16 a, b, c;
public:
    Uint16 raw16() override {
        Uint16 oa;
        oa = Uint32(a) * 0x9785u;
        a = b ^ Internals::rotate16(a, 7);
        b += c;
        c = oa;
        return c;
    }
    std::string get_name() const override {
        return "mwlac_varA";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(c);
    }
};

// From src/RNGs/other/oddball.cpp: mwlac_varB.
class Defined_mwlac_varB : public RNGs::vRNG16 {
    Uint16 a, b, c;
public:
    Uint16 raw16() override {
        Uint16 oa;
        oa = Uint32(a) * 0x9785u;
        b = Internals::rotate(b, 13);
        a = b ^ Internals::rotate16(a, 7);
        b += c;
        c = oa;
        return c;
    }
    std::string get_name() const override {
        return "mwlac_varB";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(c);
    }
};

// From src/RNGs/other/oddball.cpp: mwlac_varC.
class Defined_mwlac_varC : public RNGs::vRNG16 {
    Uint16 a, b, c;
public:
    Uint16 raw16() override {
        a = Uint16(Uint32(a) * 0x9785u);
        b = Internals::rotate16(b, 5);
        c = Internals::rotate16(c, 13);
        b ^= a;
        a ^= c;
        c += b;
        return b;
    }
    std::string get_name() const override {
        return "mwlac_varC";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(c);
    }
};

// From src/RNGs/other/oddball.cpp: mwlac_varD.
class Defined_mwlac_varD : public RNGs::vRNG16 {
    Uint16 a, b, c;
public:
    Uint16 raw16() override {
        a += b;
        b -= c;
        c += a;
        a = Uint16(Uint32(a) * 0x9785u);
        b = Internals::rotate16(b, 7);
        c = Internals::rotate16(c, 4);
        return a;
    }
    std::string get_name() const override {
        return "mwlac_varD";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(c);
    }
};

// From src/RNGs/other/oddball.cpp: mwlac_varE.
class Defined_mwlac_varE : public RNGs::vRNG16 {
    Uint16 a, b, c;
public:
    Uint16 raw16() override {
        c ^= a;
        a += b;
        b -= c;
        a += c;
        c = Uint16(Uint32(c) * 0x9785u);
        b = Internals::rotate16(b, 6);
        return a;
    }
    std::string get_name() const override {
        return "mwlac_varE";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(c);
    }
};

// From src/RNGs/other/oddball.cpp: mwlac_varF.
class Defined_mwlac_varF : public RNGs::vRNG16 {
    Uint16 a, b, c;
public:
    Uint16 raw16() override {
        a += b;
        b ^= c;
        c += a;
        a = Internals::rotate16(a, 7);
        b = Internals::rotate16(b, 5);
        c = Uint16(Uint32(c) * 0x9785u);
        Uint16 tmp = a;
        a = b; b = c; c = tmp;
        return a;
    }
    std::string get_name() const override {
        return "mwlac_varF";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(c);
    }
};

// From src/RNGs/other/oddball.cpp: mwrca16.
class Defined_mwrca16 : public RNGs::vRNG16 {
    Uint16 a, b;
public:
    Uint16 raw16() override {
        Uint16 old = Uint32(a) * 0xa395u;
        a ^= Internals::rotate16(b, 8);
        b = old;
        return a + b;
    }
    std::string get_name() const override {
        return "mwrca16";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a);
        walker->handle(b);
    }
};

// From src/RNGs/other/oddball.cpp: mwrcc16.
class Defined_mwrcc16 : public RNGs::vRNG16 {
    Uint16 a, b, counter;
public:
    Uint16 raw16() override {
        Uint16 old = Uint32(a) * 0xa395u;
        a += counter++;
        a ^= Internals::rotate16(b, 8);
        b = old;
        return a;
    }
    std::string get_name() const override {
        return "mwrcc16";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a);
        walker->handle(b);
        walker->handle(counter);
    }
};

// From src/RNGs/other/oddball.cpp: mwrcca16.
class Defined_mwrcca16 : public RNGs::vRNG16 {
    Uint16 a, b, counter;
public:
    Uint16 raw16() override {
        Uint16 old = Uint32(a) * 0xa395u;
        a += counter++;
        a ^= Internals::rotate16(b, 8);
        b = old;
        return a + b;
    }
    std::string get_name() const override {
        return "mwrcca16";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a);
        walker->handle(b);
        walker->handle(counter);
    }
};

// From src/RNGs/other/oddball.cpp: old_mwlac16.
class Defined_old_mwlac16 : public RNGs::vRNG16 {
    Uint16 a, b, c, d;
public:
    Uint16 raw16() override {
        Uint16 oa;
        oa = a;
        a = (Uint32(b) * 0x9785u) ^ (a >> 7);
        b = c + (oa >> 2);
        c = d;
        d += ~oa;
        return c;
    }
    std::string get_name() const override {
        return "old_mwlac16";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(c); walker->handle(d);
    }
};

// From src/RNGs/other/oddball.cpp: varrotC.
class Defined_varrotC : public RNGs::vRNG32 {
    Uint32 a, b, c;
public:
    Uint32 raw32() override {
        a = defined_rotate(a, c & 31) + b;
        b += c;
        c ^= a;
        b = Internals::rotate(b, 5);
        return a;
    }
    std::string get_name() const override {
        return "varrotC";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a);
        walker->handle(b);
        walker->handle(c);
    }
};

// From src/RNGs/other/simple.cpp: gjishC.
class Defined_gjishC : public RNGs::vRNG32 {
    Uint32 a, b, c;
public:
    Uint32 raw32() override {
        b += a; c = Internals::rotate32(c, 21); a ^= b;
        c += b; a = Internals::rotate32(a, 13); b ^= c;
        a += c;  c ^= a;
        return a;
    }
    std::string get_name() const override {
        return "gjishC";
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a);
        walker->handle(b);
        walker->handle(c);
    }
};

class DefinedMrc16 : public RNGs::vRNG16 {
    Uint16 a, b, counter;
public:
    explicit DefinedMrc16(SEED_NONE_TYPE) {}
    using RNGs::vRNG16::seed;
    Uint16 raw16() override {
        const Uint16 old = Uint16(Uint32(a) * 0xa965u);
        a = b + counter++;
        b = Internals::rotate16(b, 10) ^ old;
        return old + a;
    }
    void seed(Uint64 low, Uint64 = 0) override {
        a = Uint16(low); b = Uint16(low >> 16); counter = Uint16(low >> 32);
        for (unsigned i = 0; i < 9; ++i) raw16();
    }
    void walk_state(StateWalkingObject *walker) override {
        walker->handle(a); walker->handle(b); walker->handle(counter);
    }
    Uint64 get_flags() const override { return RNGs::Raw::mrc16::FLAGS; }
    std::string get_name() const override { return "mrc16"; }
};
class DefinedVeryFast16 : public Candidates::polymorphic_VeryFast16 {
public:
    explicit DefinedVeryFast16(SEED_NONE_TYPE seed) : Candidates::polymorphic_VeryFast16(seed) {}
    Uint16 raw16() override {
        const Uint16 old = implementation.a + implementation.b;
        implementation.a = Uint16(Uint32(implementation.b) * 0xa395u);
        implementation.b = Internals::rotate16(old, 7);
        return implementation.a;
    }
};
class DefinedSfcAlternative8 : public Candidates::polymorphic_sfc_alternative8 {
public:
    explicit DefinedSfcAlternative8(SEED_NONE_TYPE seed) : Candidates::polymorphic_sfc_alternative8(seed) {}
    Uint8 raw8() override {
        auto &state = implementation;
        state.a += state.b + state.c;
        state.c += 1;
        state.b ^= state.a;
        state.a = defined_rotate(state.a, 3);
        state.b = defined_rotate(state.b, 11);
        state.a += state.b;
        state.b ^= state.a;
        return state.a;
    }
};

// UB070: original names explicitly retain the captured optimized stream.
// The opt-in fixed names evaluate the intended zero rotations as identity.
// Both retain the original state walk, seeding and reverse buffer read order.
template<bool fixed, typename Word, int shift>
Word ranrot_word(Candidates::_RanrotVariant<Word, 45, 24, 0, 0, shift> &state) {
    if (state.position) return state.buffer[--state.position];
    Word prior = state.buffer[44] ^ state.counter1++;
    if (fixed) {
        for (unsigned i = 0; i < 24; ++i)
            prior = state.buffer[i] = (state.buffer[i] ^ state.buffer[i + 21]) + defined_rotate(prior, shift);
    }
    state.counter2 += state.counter1 ? 0 : 1;
    prior ^= state.counter2;
    if (fixed) {
        for (unsigned i = 24; i < 45; ++i)
            prior = state.buffer[i] = (state.buffer[i] ^ state.buffer[i - 24]) + defined_rotate(prior, shift);
    }
    state.position = 44;
    return state.buffer[state.position];
}
template<bool fixed> class Ranrot32 : public Candidates::polymorphic_ranrot_variant32 {
public:
    explicit Ranrot32(SEED_NONE_TYPE seed) : Candidates::polymorphic_ranrot_variant32(seed) {}
    Uint32 raw32() override { return ranrot_word<fixed>(implementation); }
    std::string get_name() const override { return fixed ? "ranrot_variant32_fixed" : "ranrot_variant32"; }
};
template<bool fixed> class Ranrot64 : public Candidates::polymorphic_ranrot_variant64 {
public:
    explicit Ranrot64(SEED_NONE_TYPE seed) : Candidates::polymorphic_ranrot_variant64(seed) {}
    Uint64 raw64() override { return ranrot_word<fixed>(implementation); }
    std::string get_name() const override { return fixed ? "ranrot_variant64_fixed" : "ranrot_variant64"; }
};
using LegacyRanrot32 = Ranrot32<false>;
using LegacyRanrot64 = Ranrot64<false>;
using FixedRanrot32 = Ranrot32<true>;
using FixedRanrot64 = Ranrot64<true>;
#endif
