#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "chplcast.h"
#include "chplrt.h"
#include "chpltypes.h"
#include "chplfp.h"
#include "error.h"

static int illegalFirstUnsChar(char c) {
  return ((c < '0' || c > '9') && (c != '+'));
}

/* Need to use this helper macro for PGI where doing otherwise causes
   spaces to disappear between the type name and the subsequent
   tokens */

#define _type(base, width) _##base##width

#define _define_string_to_int_precise(base, width, uns)                 \
  _type(base,width) _string_to_##base##width##_precise(const char* str, \
                                                       int* invalid,    \
                                                       char* invalidCh) { \
    char* endPtr;                                                       \
    _type(base, width) val = (_##base##width)strtol(str, &endPtr, 10);  \
    *invalid = (*str == '\0' || *endPtr != '\0');                       \
    *invalidCh = *endPtr;                                               \
    /* for negatives, strtol works, but we wouldn't want chapel to */   \
    if (*invalid == 0 && uns && illegalFirstUnsChar(*str)) {            \
      *invalid = 1;                                                     \
      *invalidCh = *str;                                                \
    }                                                                   \
    return val;                                                         \
  }

#define _define_string_to_bigint_precise(base, width, uns, format)      \
  _type(base, width)  _string_to_##base##width##_precise(const char* str, \
                                                         int* invalid,  \
                                                         char* invalidCh) { \
    _type(base, width)  val;                                            \
    int numbytes;                                                       \
    int numitems = sscanf(str, format"%n", &val, &numbytes);            \
    /* this numitems check is vague since implementations vary about    \
       whether or not to count %n as a match. */                        \
    if (numitems == 1 || numitems == 2) {                               \
      if (numbytes == strlen(str)) {                                    \
        /* for negatives, sscanf works, but we wouldn't want chapel to */ \
        if (uns && illegalFirstUnsChar(*str)) {                         \
          *invalid = 1;                                                 \
          *invalidCh = *str;                                            \
        } else {                                                        \
          *invalid = 0;                                                 \
          *invalidCh = '\0';                                            \
        }                                                               \
      } else {                                                          \
        *invalid = 1;                                                   \
        *invalidCh = *(str+numbytes);                                   \
      }                                                                 \
    } else {                                                            \
      *invalid = 1;                                                     \
      *invalidCh = *str;                                                \
    }                                                                   \
    return val;                                                         \
  }


_define_string_to_int_precise(int, 8, 0)
_define_string_to_int_precise(int, 16, 0)
_define_string_to_int_precise(int, 32, 0)
_define_string_to_bigint_precise(int, 64, 0, "%lld")
_define_string_to_int_precise(uint, 8, 1)
_define_string_to_int_precise(uint, 16, 1)
_define_string_to_int_precise(uint, 32, 1)
_define_string_to_bigint_precise(uint, 64, 1, "%llu")


_bool _string_to_bool(const char* str, int lineno, const char* filename) {
  if (string_equal(str, "true")) {
    return true;
  } else if (string_equal(str, "false")) {
    return false;
  } else {
    const char* message = 
      _glom_strings(3, 
                    "Unexpected value when converting from string to bool: '",
                    str, "'");
    _printError(message, lineno, filename);
    return false;
  }
}


#define _define_string_to_float_precise(base, width, format)            \
  _type(base, width) _string_to_##base##width##_precise(const char* str, \
                                                        int* invalid,   \
                                                        char* invalidCh) { \
    _type(base, width) val;                                             \
    int numbytes;                                                       \
    int numitems = sscanf(str, format"%n", &val, &numbytes);            \
    /* this numitems check is vague since implementations vary about    \
       whether or not to count %n as a match. */                        \
    if (numitems == 1 || numitems == 2) {                               \
      if (numbytes == strlen(str)) {                                    \
        /* for negatives, sscanf works, but we wouldn't want chapel to */ \
        *invalid = 0;                                                   \
        *invalidCh = '\0';                                              \
      } else {                                                          \
        *invalid = 1;                                                   \
        *invalidCh = *(str+numbytes);                                   \
      }                                                                 \
    } else {                                                            \
      *invalid = 1;                                                     \
      *invalidCh = *str;                                                \
    }                                                                   \
    return val;                                                         \
  }

_define_string_to_float_precise(real, 32, "%f")
_define_string_to_float_precise(real, 64, "%lf")

#define _define_string_to_imag_precise(base, width, format)             \
  _type(base, width) _string_to_##base##width##_precise(const char* str, \
                                                        int* invalid,   \
                                                        char* invalidCh) { \
    _type(base, width) val;                                             \
    int numbytes;                                                       \
    char i = '\0';                                                      \
    int numitems = sscanf(str, format"%c%n", &val, &i, &numbytes);      \
    if (numitems == 1) {                                                \
      /* missing terminating i */                                       \
      *invalid = 2;                                                     \
      *invalidCh = i;                                                   \
      /* this numitems check is vague since implementations vary about  \
         whether or not to count %n as a match. */                      \
    } else if (numitems == 2 || numitems == 3) {                        \
      if (i != 'i') {                                                   \
        *invalid = 2;                                                   \
        *invalidCh = i;                                                 \
      } else if (numbytes == strlen(str)) {                             \
        *invalid = 0;                                                   \
        *invalidCh = '\0';                                              \
      } else {                                                          \
        *invalid = 1;                                                   \
        *invalidCh = *(str+numbytes);                                   \
      }                                                                 \
    } else {                                                            \
      *invalid = 1;                                                     \
      *invalidCh = *str;                                                \
    }                                                                   \
    return val;                                                         \
  }


_define_string_to_imag_precise(imag, 32, "%f")
_define_string_to_imag_precise(imag, 64, "%lf")



#define _define_string_to_complex_precise(base, width, format, halfwidth) \
  _type(base, width) _string_to_##base##width##_precise(const char* str, \
                                                        int* invalid,   \
                                                        char* invalidCh) { \
    _type(base, width) val = {0.0, 0.0};                                \
    /* check for pure imaginary case first */                           \
    val.im = _string_to_imag##halfwidth##_precise(str, invalid, invalidCh); \
    if (*invalid) {                                                     \
      int numbytes = -1;                                                \
      char sign = '\0';                                                 \
      char i = '\0';                                                    \
      int numitems;                                                     \
      val.im = 0.0; /* reset */                                         \
      numitems = sscanf(str, format" %c "format"%c%n", &(val.re), &sign, &(val.im), &i, &numbytes); \
      if (numitems == 1) {                                              \
        *invalid = 0;                                                   \
        *invalidCh = '\0';                                              \
      } else if (numitems == 2) {                                       \
        *invalid = 1;                                                   \
        *invalidCh = sign;                                              \
      } else if (numitems == 3) {                                       \
        *invalid = 2;                                                   \
        *invalidCh = i;                                                 \
        /* this numitems check is vague since implementations vary about \
           whether or not to count %n as a match. */                    \
      } else if (numitems == 4 || numitems == 5) {                      \
        if (sign != '-' && sign != '+') {                               \
          *invalid = 1;                                                 \
          *invalidCh = sign;                                            \
        } else if (i != 'i') {                                          \
          *invalid = 1;                                                 \
          *invalidCh = i;                                               \
        } else if (numbytes == strlen(str)) {                           \
          if (sign == '-') {                                            \
            val.im = -val.im;                                           \
          }                                                             \
          *invalid = 0;                                                 \
          *invalidCh = '\0';                                            \
        } else {                                                        \
          *invalid = 1;                                                 \
          *invalidCh = *(str+numbytes);                                 \
        }                                                               \
      } else {                                                          \
        *invalid = 1;                                                   \
        *invalidCh = *str;                                              \
      }                                                                 \
    }                                                                   \
    return val;                                                         \
  }

_define_string_to_complex_precise(complex, 64, "%f", 32)
_define_string_to_complex_precise(complex, 128, "%lf", 64)




#define _define_string_to_type(base, width)                             \
  _type(base, width) _string_to_##base##width(const char* str, int lineno, \
                                              const char* filename) {   \
    int invalid;                                                        \
    char invalidStr[2] = "\0\0";                                        \
    _type(base, width) val = _string_to_##base##width##_precise(str,    \
                                                                &invalid, \
                                                                invalidStr); \
    if (invalid) {                                                      \
      const char* message;                                              \
      if (invalid == 2) {                                               \
        if (invalidStr[0] == '\0') {                                    \
          message = "Missing terminating 'i' character when converting from string to " #base "(" #width ")"; \
        } else {                                                        \
          message = _glom_strings(3, "Missing terminating 'i' character when converting from string to " #base "(" #width "); got '", invalidStr, "' instead"); \
        }                                                               \
      } else if (invalidStr[0]) {                                       \
        message = _glom_strings(3, "Illegal character when converting from string to " #base "(" #width "): '", invalidStr, "'"); \
      } else {                                                          \
        message = "Empty string when converting from string to " #base "(" #width ")"; \
      }                                                                 \
      _printError(message, lineno, filename);                           \
    }                                                                   \
    return val;                                                         \
  }

_define_string_to_type(int, 8)
_define_string_to_type(int, 16)
_define_string_to_type(int, 32)
_define_string_to_type(int, 64)
_define_string_to_type(uint, 8)
_define_string_to_type(uint, 16)
_define_string_to_type(uint, 32)
_define_string_to_type(uint, 64)

_define_string_to_type(real, 32)
_define_string_to_type(real, 64)
_define_string_to_type(imag, 32)
_define_string_to_type(imag, 64)
_define_string_to_type(complex, 64)
_define_string_to_type(complex, 128)


/*
 *  int and uint to string
 */
#define integral_to_string(type, format)        \
  _string type##_to_string(type x) {            \
    char buffer[256];                           \
    sprintf(buffer, format, x);                 \
    return string_copy(buffer);                 \
  }

integral_to_string(_int8, "%d")
integral_to_string(_int16, "%d")
integral_to_string(_int32, "%d")
integral_to_string(_int64, "%lld")
integral_to_string(_uint8, "%u")
integral_to_string(_uint16, "%u")
integral_to_string(_uint32, "%u")
integral_to_string(_uint64, "%llu")

/*
 *  real and imag to string
 */
static void ensureDecimal(char* buffer) {
  /* add decimal if one does not exist */
  if (!strchr(buffer, '.') && !strchr(buffer, 'e')) {
    if (strchr(buffer, 'i')) {
      buffer[strlen(buffer)-1] = '\0';
      strcat(buffer, ".0i");
    } else {
      strcat(buffer, ".0");
    }
  }
}

#define NANSTRING "nan"
#define NEGINFSTRING "-inf"
#define POSINFSTRING "inf"

#define real_to_string(type, format)          \
  _string type##_to_string(type x) {          \
    if (isnan(x)) {                           \
      return NANSTRING;                       \
    } else if (isinf(x)) {                    \
      if (x < 0) {                            \
        return NEGINFSTRING;                  \
      } else {                                \
        return POSINFSTRING;                  \
      }                                       \
    } else {                                  \
      char buffer[256];                       \
      sprintf(buffer, format, x);             \
      ensureDecimal(buffer);                  \
      return string_copy(buffer);             \
    }                                         \
  }

real_to_string(_real32, "%lg")
real_to_string(_real64, "%lg")
real_to_string(_real128, "%Lg")
real_to_string(_imag32, "%lgi")
real_to_string(_imag64, "%lgi")
real_to_string(_imag128, "%Lgi")
