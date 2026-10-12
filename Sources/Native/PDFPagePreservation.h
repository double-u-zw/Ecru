#ifndef ECRU_PDF_PAGE_PRESERVATION_H
#define ECRU_PDF_PAGE_PRESERVATION_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Merge only managed annotations into the original object graph; validate before returning.
// Returned memory belongs to the caller and is released with ecru_pdf_free.
int ecru_pdf_preserve_pages(const uint8_t *original, size_t original_size,
                          const uint8_t *annotated, size_t annotated_size,
                          const char *removed_slots, uint8_t **output, size_t *output_size);
// Inspect actual parsed objects and make an inert in-memory reading view. Password is never retained.
int ecru_pdf_inspect(const uint8_t *input, size_t size, const char *password,
                     uint32_t *features, uint8_t **view, size_t *view_size);
int ecru_pdf_validate(const uint8_t *original, size_t original_size,
                      const uint8_t *saved, size_t saved_size, const char *removed_slots);
void ecru_pdf_free(void *memory);
#ifdef __cplusplus
}
#endif
#endif
