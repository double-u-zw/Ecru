// Copyright 2026 double-u-zw and Ecru contributors. Apache-2.0.
#include "PDFPagePreservation.h"
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFWriter.hh>

extern "C" int ecru_pdf_preserve_pages(
    const uint8_t *original, size_t original_size,
    const uint8_t *annotated, size_t annotated_size,
    uint8_t **output, size_t *output_size) {
  *output = nullptr;
  *output_size = 0;
  try {
    QPDF source, target;
    source.setSuppressWarnings(true);
    target.setSuppressWarnings(true);
    source.processMemoryFile("original PDF", reinterpret_cast<const char *>(original), original_size);
    target.processMemoryFile("annotated PDF", reinterpret_cast<const char *>(annotated), annotated_size);
    const auto original_pages = QPDFPageDocumentHelper(source).getAllPages();
    auto target_pages = QPDFPageDocumentHelper(target).getAllPages();
    if (original_pages.size() != target_pages.size()) return 0;
    for (size_t i = 0; i < original_pages.size(); ++i) {
      auto original_page = original_pages[i];
      auto page = target_pages[i].getObjectHandle();
      // PDFKit remains responsible for annotations and their appearance streams.
      // Never keep Quartz's rewritten page drawing or renamed font/image resources.
      for (const auto *key : {"/Contents", "/Resources"}) {
        auto object = original_page.getAttribute(key, false);
        if (object.isNull()) {
          page.removeKey(key);
        } else {
          if (!object.isIndirect()) object = source.makeIndirectObject(object);
          page.replaceKey(key, target.copyForeignObject(object));
        }
      }
    }
    QPDFWriter writer(target);
    writer.setOutputMemory();
    writer.setStreamDataMode(qpdf_s_preserve);
    writer.write();
    auto buffer = writer.getBufferSharedPointer();
    auto memory = static_cast<uint8_t *>(std::malloc(buffer->getSize()));
    if (!memory) return 0;
    std::memcpy(memory, buffer->getBuffer(), buffer->getSize());
    *output = memory;
    *output_size = buffer->getSize();
    return 1;
  } catch (const std::exception &) {
    return 0;
  }
}
extern "C" void ecru_pdf_free(void *memory) { std::free(memory); }
