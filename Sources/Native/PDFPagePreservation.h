#ifndef ECRU_PDF_PAGE_PRESERVATION_H
#define ECRU_PDF_PAGE_PRESERVATION_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Reattach original page drawing/resources to the PDFKit annotation export.
// Returned memory belongs to the caller and is released with ecru_pdf_free.
int ecru_pdf_preserve_pages(const uint8_t *original, size_t original_size,
                          const uint8_t *annotated, size_t annotated_size,
                          uint8_t **output, size_t *output_size);
void ecru_pdf_free(void *memory);
#ifdef __cplusplus
}
#endif
#endif
