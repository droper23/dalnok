// REAPER .rpp import. RPP is a line-based text format of nested <BLOCK ...> ... >
// sections. Times are in seconds. Imports tracks (name, volume, pan, mute,
// solo) and audio items (position, length, source offset, fades, item volume,
// looping). Reports MIDI, FX, automation, folders, extra takes, and rate changes.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "import/import.hpp"

#include <cmath>
#include <filesystem>
#include <fstream>
#include <memory>
#include <sstream>

namespace fs = std::filesystem;

namespace dalnok::import {

namespace {

struct Node {
    std::vector<std::string> head;               // block name + args
    std::vector<std::vector<std::string>> lines; // plain lines (tokenized)
    std::vector<std::unique_ptr<Node>> children;

    const std::vector<std::string> *line(const std::string &key) const {
        for (const auto &l : lines)
            if (!l.empty() && l[0] == key) return &l;
        return nullptr;
    }
    double num(const std::string &key, size_t i, double fallback) const {
        const auto *l = line(key);
        if (!l || l->size() <= i) return fallback;
        try { return std::stod((*l)[i]); } catch (...) { return fallback; }
    }
    std::string str(const std::string &key, size_t i = 1) const {
        const auto *l = line(key);
        return l && l->size() > i ? (*l)[i] : std::string();
    }
    std::vector<const Node *> blocks(const std::string &name) const {
        std::vector<const Node *> out;
        for (const auto &c : children)
            if (!c->head.empty() && c->head[0] == name) out.push_back(c.get());
        return out;
    }
};

// Tokens: whitespace-separated; "double", 'single' or `backtick` quotes group words.
std::vector<std::string> tokenize(const std::string &s) {
    std::vector<std::string> out;
    size_t i = 0;
    while (i < s.size()) {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r')) ++i;
        if (i >= s.size()) break;
        const char q = s[i];
        if (q == '"' || q == '\'' || q == '`') {
            const size_t e = s.find(q, i + 1);
            out.push_back(s.substr(i + 1, (e == std::string::npos ? s.size() : e) - i - 1));
            i = e == std::string::npos ? s.size() : e + 1;
        } else {
            size_t e = i;
            while (e < s.size() && s[e] != ' ' && s[e] != '\t' && s[e] != '\r') ++e;
            out.push_back(s.substr(i, e - i));
            i = e;
        }
    }
    return out;
}

bool parseRpp(std::istream &in, Node &root, std::string &err) {
    std::vector<Node *> stack{&root};
    std::string raw;
    int lineNo = 0;
    while (std::getline(in, raw)) {
        ++lineNo;
        const auto first = raw.find_first_not_of(" \t");
        if (first == std::string::npos) continue;
        if (raw[first] == '<') {
            auto n = std::make_unique<Node>();
            n->head = tokenize(raw.substr(first + 1));
            Node *ptr = n.get();
            stack.back()->children.push_back(std::move(n));
            stack.push_back(ptr);
        } else if (raw[first] == '>') {
            if (stack.size() <= 1) {
                err = "unbalanced '>' at line " + std::to_string(lineNo);
                return false;
            }
            stack.pop_back();
        } else {
            stack.back()->lines.push_back(tokenize(raw.substr(first)));
        }
    }
    if (stack.size() != 1) {
        err = "unterminated block";
        return false;
    }
    return true;
}

// Counts nested blocks with a given name anywhere below `n`.
int countBlocks(const Node &n, const std::string &name) {
    int c = 0;
    for (const auto &ch : n.children) {
        if (!ch->head.empty() && ch->head[0] == name) ++c;
        c += countBlocks(*ch, name);
    }
    return c;
}

int countFx(const Node &track) {
    int c = 0;
    for (const auto *chain : track.blocks("FXCHAIN"))
        for (const auto &ch : chain->children)
            if (!ch->head.empty() && (ch->head[0] == "VST" || ch->head[0] == "AU" || ch->head[0] == "JS" ||
                                      ch->head[0] == "CLAP" || ch->head[0] == "LV2" || ch->head[0] == "DX"))
                ++c;
    return c;
}

std::string resolvePath(const std::string &file, const fs::path &projectDir) {
    return locateMedia(file, projectDir.string());
}

} // namespace

bool importReaper(const std::string &path, Result &out, std::string &err) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        err = "cannot open " + path;
        return false;
    }
    Node root;
    if (!parseRpp(in, root, err)) {
        err = "not a valid REAPER project: " + err;
        return false;
    }
    const auto projects = root.blocks("REAPER_PROJECT");
    if (projects.empty()) {
        err = "not a REAPER project (no <REAPER_PROJECT> block)";
        return false;
    }
    const Node &proj = *projects[0];
    Report &rep = out.report;
    rep.app = "REAPER";
    rep.version = proj.head.size() > 2 ? proj.head[2] : "";
    const fs::path projectDir = fs::absolute(fs::path(path)).parent_path();

    double rate = proj.num("SAMPLERATE", 1, 0);
    if (!(rate >= 8000 && rate <= 768000)) rate = 48000;
    Builder b(rep, rate);

    for (const Node *env : proj.blocks("TEMPOENVEX")) {
        int points = 0;
        for (const auto &l : env->lines) points += !l.empty() && l[0] == "PT";
        if (points > 1) rep.skip("tempoChanges");
    }
    if (const auto mv = proj.num("MASTER_VOLUME", 1, 1); std::fabs(mv - 1) > 1e-6) {
        rep.skip("masterVolume");
        rep.notes.push_back("Master volume was " + std::to_string(linearToDb(mv)).substr(0, 5) + " dB; Dalnok has no master fader yet.");
    }
    for (const Node *mfx : proj.blocks("MASTERFXLIST"))
        for (const auto &ch : mfx->children)
            if (!ch->head.empty() && ch->head[0] != "FXCHAIN") rep.skip("masterFx");

    int stretchedItems = 0;
    for (const Node *t : proj.blocks("TRACK")) {
        const double vol = t->num("VOLPAN", 1, 1), pan = t->num("VOLPAN", 2, 0);
        const bool mute = t->num("MUTESOLO", 1, 0) != 0, solo = t->num("MUTESOLO", 2, 0) != 0;
        std::string name = t->str("NAME");
        const int track = b.addTrack(name, linearToDb(vol), static_cast<float>(pan), mute, solo);

        if (t->num("ISBUS", 1, 0) != 0) rep.skip("folderStructure");
        rep.skip("plugins", countFx(*t));
        rep.skip("automationLanes", countBlocks(*t, "VOLENV2") + countBlocks(*t, "PANENV2") + countBlocks(*t, "VOLENV") +
                                        countBlocks(*t, "PANENV") + countBlocks(*t, "MUTEENV") + countBlocks(*t, "PARMENV"));
        if (t->line("AUXRECV")) rep.skip("sends");

        for (const Node *item : t->blocks("ITEM")) {
            if (item->num("MUTE", 1, 0) != 0) {
                rep.skip("mutedItems");
                continue;
            }
            const auto sources = item->blocks("SOURCE");
            if (sources.empty()) continue;
            int takes = 0;
            for (const auto &l : item->lines) takes += !l.empty() && l[0] == "TAKE";
            rep.skip("extraTakes", takes);
            const Node *src = sources[0]; // first take
            std::string type = src->head.size() > 1 ? src->head[1] : "";
            if (type == "SECTION") {
                rep.skip("sectionOrReversedSources");
                const auto inner = src->blocks("SOURCE");
                if (inner.empty()) continue;
                src = inner[0];
                type = src->head.size() > 1 ? src->head[1] : "";
            }
            if (type == "MIDI" || type == "MIDIPOOL") {
                rep.skip("midiClips");
                continue;
            }
            if (type == "EMPTY" || type == "VIDEO" || type == "CLICK" || type == "LTC") {
                rep.skip("nonAudioItems");
                continue;
            }
            const std::string file = resolvePath(src->str("FILE"), projectDir);
            if (file.empty()) continue;
            const int media = b.addMedia(file);

            const double position = item->num("POSITION", 1, 0), length = item->num("LENGTH", 1, 0);
            const double soffs = item->num("SOFFS", 1, 0);
            // PLAYRATE rate preservePitch pitchSemitones ...
            Builder::Stretch st{item->num("PLAYRATE", 1, 1), static_cast<float>(item->num("PLAYRATE", 3, 0)),
                                item->num("PLAYRATE", 2, 1) != 0};
            if (std::fabs(st.rate - 1) > 1e-6 || st.pitch != 0) ++stretchedItems;
            const float itemGain = linearToDb(item->num("VOLPAN", 1, 1));
            const auto fade = [&](const char *key) {
                const double len = item->num(key, 2, 0), autoLen = item->num(key, 3, 0);
                return std::max(len, autoLen);
            };
            const double fin = fade("FADEIN"), fout = fade("FADEOUT");
            const bool equalPower = item->num("FADEIN", 1, 0) != 0 || item->num("FADEOUT", 1, 0) != 0;
            const std::string name = item->str("NAME");
            const double srcLen = b.mediaSeconds(media);
            if (item->num("LOOP", 1, 0) != 0 && srcLen > 0 && soffs + length * st.rate > srcLen + 1e-6) {
                b.addLoopedClip(track, media, position, length, std::fmod(soffs, srcLen), 0, srcLen, name, itemGain, st);
                if (fin > 0 || fout > 0) rep.skip("fadesOnLoopedItems");
            } else {
                b.addClip(track, media, position, soffs, length, name, itemGain, fin, fout, equalPower, st);
            }
        }
    }
    if (stretchedItems) rep.notes.push_back(std::to_string(stretchedItems) + " item(s) with a changed playback rate or pitch were time-stretched to match.");
    out.document = b.document();
    const double tempo = proj.num("TEMPO", 1, 120), num = proj.num("TEMPO", 2, 4), den = proj.num("TEMPO", 3, 4);
    out.document.set("tempo", tempo >= 20 && tempo <= 400 ? tempo : 120);
    json::Value meter = json::Value::makeArray();
    meter.push(num >= 1 && num <= 32 && std::floor(num) == num ? static_cast<int>(num) : 4);
    meter.push(den == 1 || den == 2 || den == 4 || den == 8 || den == 16 ? static_cast<int>(den) : 4);
    out.document.set("meter", std::move(meter));
    if (rep.missingMedia) rep.notes.push_back(std::to_string(rep.missingMedia) + " audio file(s) not found; clips are offline until relinked.");
    return true;
}

} // namespace dalnok::import
