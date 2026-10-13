// Copyright 2026 double-u-zw and Ecru contributors. Apache-2.0.
#include "PDFPagePreservation.h"
#include <cstdlib>
#include <cstring>
#include <map>
#include <functional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFWriter.hh>

namespace {
using H = QPDFObjectHandle;
#define require(ok) do { if (!(ok)) throw std::runtime_error("PDF integrity line " + std::to_string(__LINE__)); } while (0)
void load(QPDF& q, const uint8_t* bytes, size_t n, const char* password = nullptr) {
  q.setSuppressWarnings(true);
  q.setAttemptRecovery(false);
  q.processMemoryFile("PDF", reinterpret_cast<const char*>(bytes), n, password);
}
void output(QPDF& q, uint8_t** out, size_t* n) {
  QPDFWriter w(q); w.setOutputMemory(); w.setStreamDataMode(qpdf_s_preserve);
  w.setCompressStreams(false); w.setPreserveUnreferencedObjects(true); w.write();
  require(!q.anyWarnings());
  auto b = w.getBufferSharedPointer();
  *out = static_cast<uint8_t*>(std::malloc(b->getSize())); require(*out != nullptr);
  std::memcpy(*out, b->getBuffer(), b->getSize()); *n = b->getSize();
}
std::map<int, std::set<int>> slots(const char* raw) {
  std::map<int, std::set<int>> result; std::istringstream in(raw ? raw : "");
  int page, slot; char colon;
  while (in >> page >> colon >> slot) { require(colon == ':' && page >= 0 && slot >= 0); result[page].insert(slot); }
  return result;
}
// Walk direct dictionaries too: actions/signature dictionaries need not be indirect.
void walk(QPDF& q, const std::function<void(H)>& fn) {
  size_t budget=1000000;
  std::function<void(H,int)> visit = [&](H o,int depth) {
    require(budget-- > 0 && depth < 128);
    if(o.isStream()) o=o.getDict();
    if(o.isDictionary()) {
      fn(o);
      for(auto k:o.getKeys()) { auto child=o.getKey(k); if(!child.isIndirect()) visit(child,depth+1); }
    } else if(o.isArray()) for(int i=0;i<o.getArrayNItems();++i) { auto child=o.getArrayItem(i); if(!child.isIndirect()) visit(child,depth+1); }
  };
  for(auto o:q.getAllObjects()) visit(o,0);
}
// Common slide generators embed viewer-local navigation commands. Ecru's
// input router never executes PDFActionNamed, but these inert commands can be
// preserved in the original graph without disabling all annotation editing.
bool local_navigation(H o) {
  if (!o.getKey("/S").isNameAndEquals("/Named")) return false;
  auto name = o.getKey("/N");
  for (auto allowed : {"/FirstPage", "/LastPage", "/NextPage", "/PrevPage",
                       "/Find", "/GoBack", "/GoForward", "/GoToPage"})
    if (name.isNameAndEquals(allowed)) return true;
  return false;
}
bool navigation_action(H o, int depth = 0) {
  if (depth > 16 || !o.isDictionary() || o.hasKey("/JS") || o.hasKey("/JavaScript") ||
      !(o.getKey("/S").isNameAndEquals("/GoTo") || local_navigation(o))) return false;
  auto next = o.getKey("/Next");
  if (next.isNull()) return true;
  if (!next.isArray()) return navigation_action(next, depth + 1);
  for (int i = 0; i < next.getArrayNItems(); ++i)
    if (!navigation_action(next.getArrayItem(i), depth + 1)) return false;
  return true;
}
bool manual_action(H o) {
  return navigation_action(o) || (o.isDictionary() && o.getKey("/S").isNameAndEquals("/URI") &&
      o.getKey("/Next").isNull() && !o.hasKey("/JS") && !o.hasKey("/JavaScript"));
}
bool navigation_triggers(H o) {
  if (!o.isDictionary()) return false;
  for (auto key : o.getKeys()) if (!navigation_action(o.getKey(key))) return false;
  return true;
}
uint32_t features(QPDF& q) {
  uint32_t f = q.isEncrypted() ? 1 : 0;
  auto root = q.getRoot();
  if (root.hasKey("/AcroForm")) f |= 4;
  if (root.getKey("/AcroForm").isDictionary() && root.getKey("/AcroForm").hasKey("/XFA")) f |= 8;
  if (root.hasKey("/Collection")) f |= 64;
  if (root.hasKey("/Perms")) f |= 128;
  auto opening = root.getKey("/OpenAction");
  if (opening.isDictionary() && !navigation_action(opening)) f |= 32;
  walk(q, [&](H o) {
    if (o.getKey("/FT").isNameAndEquals("/Sig") || o.getKey("/Type").isNameAndEquals("/Sig") || o.hasKey("/ByteRange")) f |= 2;
    if (o.hasKey("/XFA")) f |= 8;
    if (o.hasKey("/EmbeddedFiles") || o.hasKey("/EF") || o.hasKey("/AF") || o.getKey("/Subtype").isNameAndEquals("/FileAttachment")) f |= 16;
    auto action = o.getKey("/S"); auto subtype = o.getKey("/Subtype");
    if (o.hasKey("/JavaScript") || o.hasKey("/JS") || (o.hasKey("/AA") && !navigation_triggers(o.getKey("/AA"))) ||
        action.isNameAndEquals("/JavaScript") || action.isNameAndEquals("/Launch") ||
        action.isNameAndEquals("/GoToR") || action.isNameAndEquals("/SubmitForm") ||
        action.isNameAndEquals("/ImportData") || action.isNameAndEquals("/Rendition") ||
        action.isNameAndEquals("/GoToE") || action.isNameAndEquals("/Thread") ||
        action.isNameAndEquals("/Sound") || action.isNameAndEquals("/Movie") ||
        action.isNameAndEquals("/Hide") || (action.isNameAndEquals("/Named") && !local_navigation(o)) ||
        action.isNameAndEquals("/ResetForm") || action.isNameAndEquals("/SetOCGState") ||
        action.isNameAndEquals("/Trans") || action.isNameAndEquals("/GoTo3DView") ||
        (o.getKey("/Type").isNameAndEquals("/Action") && !action.isNameAndEquals("/GoTo") && !action.isNameAndEquals("/URI") && !local_navigation(o)) ||
        subtype.isNameAndEquals("/RichMedia") || subtype.isNameAndEquals("/Movie") ||
        subtype.isNameAndEquals("/Sound") || subtype.isNameAndEquals("/Screen") || subtype.isNameAndEquals("/3D")) f |= 32;
  });
  if (q.anyWarnings()) f |= 256;
  return f;
}
// Compare graphs with a bijection of indirect references. This checks both object
// values and shared relationships (field/widget trees, name trees, file specs).
// Cycles are visited once. Raw stream bytes and their complete dictionaries match.
struct GraphCheck {
  std::map<QPDFObjGen, QPDFObjGen> forward, reverse;
  std::set<QPDFObjGen> pages;
  size_t budget = 1000000;
  void equal(H a, H b, int depth = 0, bool streamDict = false) {
    require(budget-- > 0 && depth < 256);
    require(a.getTypeCode() == b.getTypeCode());
    if (a.isIndirect()) {
      require(b.isIndirect()); auto x = a.getObjGen(), y = b.getObjGen();
      if (forward.count(x)) { require(forward[x] == y); return; }
      require(!reverse.count(y)); forward[x] = y; reverse[y] = x;
    }
    if (a.isStream()) {
      auto x = a.getRawStreamData(), y = b.getRawStreamData();
      require(x->getSize() == y->getSize() && std::memcmp(x->getBuffer(), y->getBuffer(), x->getSize()) == 0);
      equal(a.getDict(), b.getDict(), depth+1, true); return;
    }
    if (a.isDictionary()) {
      auto ak = a.getKeys(), bk = b.getKeys();
      if (a.isIndirect() && pages.count(a.getObjGen())) { ak.erase("/Annots"); bk.erase("/Annots"); }
      // Stream length may be represented by a direct or indirect integer by QPDF.
      if(streamDict) { ak.erase("/Length"); bk.erase("/Length"); } require(ak == bk);
      for (const auto& k : ak) equal(a.getKey(k), b.getKey(k), depth+1);
    } else if (a.isArray()) {
      require(a.getArrayNItems() == b.getArrayNItems());
      for (int i=0; i<a.getArrayNItems(); ++i) equal(a.getArrayItem(i), b.getArrayItem(i), depth+1);
    } else { require(a.unparseResolved() == b.unparseResolved()); }
  }
};
void validate(QPDF& source, QPDF& saved, const char* removed) {
  require(!source.isEncrypted() && !saved.isEncrypted());
  auto a = QPDFPageDocumentHelper(source).getAllPages(); auto b = QPDFPageDocumentHelper(saved).getAllPages();
  require(a.size() == b.size()); auto removedSlots = slots(removed); GraphCheck check;
  for (auto p : a) check.pages.insert(p.getObjectHandle().getObjGen());
  check.equal(source.getRoot(), saved.getRoot());
  // Preserve every trailer extension, metadata entry and non-ID trailer object.
  auto at = source.getTrailer(), bt = saved.getTrailer();
  for (auto k : at.getKeys()) if (k != "/ID" && k != "/Size" && k != "/Prev" && k != "/XRefStm" && k != "/Type" && k != "/W" && k != "/Index" && k != "/Length" && k != "/Filter" && k != "/DecodeParms") check.equal(at.getKey(k), bt.getKey(k));
  for (size_t p=0; p<a.size(); ++p) {
    auto old = a[p].getObjectHandle().getKey("/Annots"), now = b[p].getObjectHandle().getKey("/Annots"); int retained = 0;
    if (old.isArray()) for (int i=0; i<old.getArrayNItems(); ++i) if (!removedSlots[p].count(i)) {
      require(now.isArray() && retained < now.getArrayNItems()); check.equal(old.getArrayItem(i), now.getArrayItem(retained++));
    }
  }
  require(!source.anyWarnings() && !saved.anyWarnings());
}
}
extern "C" int ecru_pdf_inspect(const uint8_t* input, size_t size, const char* password,
                                uint32_t* flags, uint8_t** view, size_t* view_size) {
  *view = nullptr; *view_size = 0; *flags = 0;
  try {
    QPDF q; load(q,input,size,password); *flags = features(q);
    bool inert_navigation = false;
    walk(q, [&](H o) { if (o.hasKey("/AA") || o.getKey("/OpenAction").isDictionary()) inert_navigation = true; });
    // Inert display graph only. The original bytes remain the immutable save base.
    // Never execute actions, including automatically triggered document/field actions.
    walk(q, [&](H o) {
      bool keep_manual_action = manual_action(o);
      if (o.hasKey("/A") && !manual_action(o.getKey("/A"))) o.removeKey("/A");
      for (auto k : {"/AA", "/OpenAction", "/JS", "/JavaScript", "/XFA", "/RichMediaContent", "/RichMediaSettings", "/Movie", "/Sound", "/3DD", "/3DA"}) o.removeKey(k);
      // Keep /S in graphics, structure and file dictionaries; only actions use /Type /Action.
      if (!keep_manual_action && o.getKey("/Type").isNameAndEquals("/Action")) { o.removeKey("/S"); o.removeKey("/Next"); }
    });
    if ((*flags & (1|8|32|64|256)) != 0 || inert_navigation) {
      // Encryption is only removed from this transient reading view, never exported.
      QPDFWriter w(q); w.setOutputMemory(); w.setPreserveEncryption(false); w.setStreamDataMode(qpdf_s_preserve); w.write();
      auto b=w.getBufferSharedPointer(); *view=static_cast<uint8_t*>(std::malloc(b->getSize())); require(*view != nullptr);
      std::memcpy(*view,b->getBuffer(),b->getSize()); *view_size=b->getSize();
    }
    return 1;
  } catch (const std::exception&) { if (*view) std::free(*view); *view=nullptr; *view_size=0; return 0; }
}
extern "C" int ecru_pdf_preserve_pages(const uint8_t* original, size_t original_size,
    const uint8_t* annotated, size_t annotated_size, const char* removed,
    uint8_t** out, size_t* out_size) {
  *out=nullptr; *out_size=0;
  try {
    QPDF source, target; load(source,original,original_size); load(target,annotated,annotated_size);
    require((features(source) & (1|2|8|32|64|128|256)) == 0);
    auto oldPages=QPDFPageDocumentHelper(source).getAllPages(); auto newPages=QPDFPageDocumentHelper(target).getAllPages();
    require(oldPages.size()==newPages.size()); auto removedSlots=slots(removed);
    for (size_t p=0;p<oldPages.size();++p) {
      auto page=oldPages[p].getObjectHandle(); auto old=page.getKey("/Annots"); auto incoming=newPages[p].getObjectHandle().getKey("/Annots");
      auto merged=H::newArray(); int retained=0;
      if(old.isArray()) for(int i=0;i<old.getArrayNItems();++i) if(!removedSlots[p].count(i)) { merged.appendItem(old.getArrayItem(i)); ++retained; }
      const int incomingCount=incoming.isArray() ? incoming.getArrayNItems() : 0;
      require((incoming.isArray() || incoming.isNull()) && incomingCount>=retained);
      for(int i=retained;i<incomingCount;++i) {
        auto object=incoming.getArrayItem(i); if(!object.isIndirect()) object=target.makeIndirectObject(object);
        auto copy=source.copyForeignObject(object); copy.replaceKey("/P",page); merged.appendItem(copy);
      }
      page.replaceKey("/Annots",merged);
    }
    output(source,out,out_size);
    QPDF originalGraph, saved; load(originalGraph,original,original_size); load(saved,*out,*out_size);
    validate(originalGraph,saved,removed); return 1;
  } catch (const std::exception&) { if(*out) std::free(*out); *out=nullptr; *out_size=0; return 0; }
}
extern "C" int ecru_pdf_validate(const uint8_t* original,size_t original_size,const uint8_t* saved,size_t saved_size,const char* removed) {
  try { QPDF a,b; load(a,original,original_size); load(b,saved,saved_size); validate(a,b,removed); return 1; }
  catch(const std::exception&) { return 0; }
}
extern "C" void ecru_pdf_free(void* memory) { std::free(memory); }
