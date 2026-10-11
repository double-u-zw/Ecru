#ifndef ECRU_INK_MODELER_BRIDGE_H
#define ECRU_INK_MODELER_BRIDGE_H
#include "PDFPagePreservation.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { double x, y, factor; } EcruModeledPoint;
void *ecru_ink_create(double x, double y, double factor);
void ecru_ink_destroy(void *handle);
// Positive return: number of stable points followed by provisional points.
// Negative return: malformed input/model failure, with no partial output.
int ecru_ink_update(void *handle, double x, double y, double factor, double time,
                    int release, EcruModeledPoint *points, int capacity, int *stable_count);
// Google Ink owns the complete modeled brush shape. Borrowed outline memory
// stays valid until the next outline read or destruction; copy before returning.
typedef struct { double x, y; int starts_contour; } EcruInkVertex;
const char *ecru_google_ink_configuration(void);
void *ecru_google_ink_create(double x, double y, double width, double pressure);
void *ecru_google_ink_create_scaled(double x, double y, double width, double pressure, double view_scale);
void ecru_google_ink_destroy(void *handle);
int ecru_google_ink_update(void *handle, double x, double y, double pressure, double elapsed, int release);
int ecru_google_ink_outline(void *handle, const EcruInkVertex **vertices);
#ifdef __cplusplus
}
#endif
#endif
