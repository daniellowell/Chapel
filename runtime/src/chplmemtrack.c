#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>

#include "chplrt.h"
#include "chplmemtrack.h"
#include "chapel_code.h"
#include "chplthreads.h"
#include "chplcomm.h"
#include "error.h"

#undef malloc
#undef calloc
#undef free

#define MEM_DIAGNOSIS 0
static int memDiagnosisFlag = 0;

#define CHPL_DEBUG_MEMTRACK 0
#define PRINTF(s) do if (CHPL_DEBUG_MEMTRACK) \
                       { printf("%s%s\n", __func__, s); fflush(stdout); } while (0)

typedef struct memTableEntry_struct { /* table entry */
  size_t number;
  size_t size;
  chpl_memDescInt_t description;
  void* memAlloc;
  int32_t lineno;
  chpl_string filename;
  struct memTableEntry_struct* nextInBucket;
} memTableEntry;

#define HASHSIZE 1019

static memTableEntry* memTable[HASHSIZE];

static _Bool memfinalstat = false;
static _Bool memstat = false;
static _Bool memtrace = false;
static _Bool memtrack = false;
static _Bool memfinalstatSet = false;
static _Bool memstatSet = false;
static _Bool memtraceSet = false;
static _Bool memtrackSet = false;

static int64_t memmaxValue = 0;
static int64_t memthresholdValue = 1;
static FILE* memlog = NULL;
static size_t totalMem = 0;         /* total memory currently allocated */
static size_t totalTrackedMem = 0;  /* total memory being tracked */
static size_t maxMem = 0;           /* maximum total memory during run  */

static _Bool alreadyPrintingStat = false;

#ifndef LAUNCHER
static chpl_mutex_t memtrack_lock;
static chpl_mutex_t memstat_lock;
static chpl_mutex_t memtrace_lock;
#endif

static unsigned hash(void* memAlloc);
static void updateMaxMem(void);
static memTableEntry* removeBucketEntry(void* address);
static memTableEntry* lookupMemoryNoLock(void* memAlloc);
static memTableEntry* lookupMemory(void* memAlloc);


/* hashing function */
static unsigned hash(void* memAlloc) {
  unsigned hashValue = 0;
  char* fakeCharPtr = (char*)&memAlloc;
  size_t i;
  for (i = 0; i < sizeof(void*); i++) {
    hashValue = *fakeCharPtr + 31 * hashValue;
    fakeCharPtr++;
  }
  return hashValue % HASHSIZE;
}


static inline void updateMaxMem(void) {
  if (totalTrackedMem > maxMem)
    maxMem = totalTrackedMem;
}


static memTableEntry* lookupMemoryNoLock(void* memAlloc) {
  memTableEntry* memEntry = NULL;
  memTableEntry* found = NULL;
  unsigned hashValue = hash(memAlloc);

  for (memEntry = memTable[hashValue];
       memEntry != NULL;
       memEntry = memEntry->nextInBucket) {

    if (memEntry->memAlloc == memAlloc) {
      found = memEntry;
      break;
    }
  }
  return found;
}


static memTableEntry* removeBucketEntry(void* address) {
  unsigned hashValue = hash(address);
  memTableEntry* thisBucketEntry = memTable[hashValue];
  memTableEntry* deletedBucket = NULL;

  if (thisBucketEntry->memAlloc == address) {
    memTable[hashValue] = thisBucketEntry->nextInBucket;
    deletedBucket = thisBucketEntry;
  } else {
    for (thisBucketEntry = memTable[hashValue];
         thisBucketEntry != NULL;
         thisBucketEntry = thisBucketEntry->nextInBucket) {

      memTableEntry* nextBucketEntry = thisBucketEntry->nextInBucket;

      if (nextBucketEntry && nextBucketEntry->memAlloc == address) {
        thisBucketEntry->nextInBucket = nextBucketEntry->nextInBucket;
        deletedBucket = nextBucketEntry;
      }
    }
  }
  if (deletedBucket == NULL) {
    chpl_internal_error("Hash table entry has disappeared unexpectedly!");
  }
  return deletedBucket;
}


void chpl_initMemTable(void) {
  chpl_mutex_init(&memtrace_lock);
  chpl_mutex_init(&memstat_lock);
  chpl_mutex_init(&memtrack_lock);
  if (memtrack) {
    int i;
    for (i = 0; i < HASHSIZE; i++) {
      memTable[i] = NULL;
    }
  }
}

void chpl_setMemmax(int64_t value) {
  memmaxValue = value;
  chpl_setMemstat();
}


void chpl_setMemstat(void) {
  memstatSet = true;
  memtrackSet = true;
}


void chpl_setMemfinalstat(void) {
  memfinalstatSet = true;
  memtrackSet = true;
}


void chpl_setMemtrack(void) {
  memtrackSet = true;
}


void chpl_setMemthreshold(int64_t value) {
  if (!memlog && !memfinalstatSet) {
    chpl_error("--memthreshold useless when used without --memtrace or --memfinalstat", 0, 0);
  }
  memthresholdValue = value >= 0 ? value : -value;
  if (memthresholdValue < 0)
    memthresholdValue = INT64_MAX;
}


void chpl_setMemtrace(char* memlogname) {
  memtraceSet = true;
  if (memlogname) {
    if (strcmp(memlogname, "-")) {
      memlog = fopen(memlogname, "w");
      if (!memlog)
        chpl_error(chpl_glom_strings(3, "Unable to open \"", memlogname, "\""), 0, 0);
    } else
      memlog = stdout;
  }
}


static void increaseMemStat(size_t chunk, int32_t lineno, chpl_string filename) {
  chpl_mutex_lock(&memstat_lock);
  totalMem += chunk;
  if (memmaxValue && (totalMem > memmaxValue)) {
    chpl_mutex_unlock(&memstat_lock);
    chpl_error("Exceeded memory limit", lineno, filename);
  }
  totalTrackedMem += chunk;
  updateMaxMem();
  chpl_mutex_unlock(&memstat_lock);
}


static void decreaseMemStat(size_t chunk) {
  chpl_mutex_lock(&memstat_lock);
  totalMem = chunk > totalMem ? 0 : totalMem - chunk;
  totalTrackedMem = chunk > totalTrackedMem ? 0 : totalTrackedMem - chunk;
  chpl_mutex_unlock(&memstat_lock);
}


void chpl_resetMemStat(void) {
  totalMem = 0;
  totalTrackedMem = 0;
  maxMem = 0;
}

void chpl_startTrackingMem(void) {
    memfinalstat = memfinalstatSet;
    memstat = memstatSet;
    memtrack = memtrackSet;
    memtrace = memtraceSet;
}

uint64_t chpl_memoryUsed(int32_t lineno, chpl_string filename) {
  alreadyPrintingStat = true; /* hack: don't want to print final stats */
  if (!memstat)
    chpl_error("memoryUsed() only works with the --memstat flag",
               lineno, filename);
  return (uint64_t)totalMem;
}


void chpl_printMemStat(int32_t lineno, chpl_string filename) {
  if (!memstat)
    chpl_error("printMemStat() only works with the --memstat flag",
               lineno, filename);
  chpl_mutex_lock(&memstat_lock);
  printf("totalMem=%zu, maxMem=%zu\n", totalTrackedMem, maxMem);
  alreadyPrintingStat = true;
  chpl_mutex_unlock(&memstat_lock);
}


#ifndef LAUNCHER
static int leakedMemTableEntryCmp(const void* p1, const void* p2) {
  return *(size_t*)p2 - *(size_t*)p1;
}

static void chpl_printLeakedMemTable(void) {
  size_t* table;
  memTableEntry* me;
  int i;
  const int numberWidth   = 9;
  const int numEntries = CHPL_RT_MD_NUM+chpl_num_memDescs;

  table = (size_t*)calloc(numEntries, 3*sizeof(size_t));

  for (i = 0; i < HASHSIZE; i++) {
    for (me = memTable[i]; me != NULL; me = me->nextInBucket) {
      table[3*me->description] += me->number*me->size;
      table[3*me->description+1] += 1;
      table[3*me->description+2] = me->description;
    }
  }

  qsort(table, numEntries, 3*sizeof(size_t), leakedMemTableEntryCmp);

  printf("\n====================");
  printf("\nLeaked Memory Report");
  printf("\n==============================================================");
  printf("\nNumber of leaked allocations");
  printf("\n           Total leaked memory (bytes)");
  printf("\n                      Description of allocation");
  printf("\n==============================================================");
  for (i = 0; i < 3*(CHPL_RT_MD_NUM+chpl_num_memDescs); i += 3) {
    if (table[i] > 0) {
      printf("\n%*zu  %*zu  %s",
             numberWidth, table[i+1],
             numberWidth, table[i],
             chpl_memDescString(table[i+2]));
    }
  }
  printf("\n==============================================================\n");

  free(table);
}
#endif


void chpl_reportMemInfo() {
  if (!alreadyPrintingStat && memstat) {
    printf("Final Memory Statistics:  ");
    chpl_printMemStat(0, 0);
  }
#ifndef LAUNCHER
  if (memfinalstat) {
    chpl_printLeakedMemTable();
  }
#endif
}


static int descCmp(const void* p1, const void* p2) {
  memTableEntry* m1 = *(memTableEntry**)p1;
  memTableEntry* m2 = *(memTableEntry**)p2;

  int val = strcmp(chpl_memDescString(m1->description), chpl_memDescString(m2->description));
  if (val == 0 && m1->filename && m2->filename)
    val = strcmp(m1->filename, m2->filename);
  if (val == 0)
    val = (m1->lineno < m2->lineno) ? -1 : ((m1->lineno > m2->lineno) ? 1 : 0);
  return val;
}


void chpl_printMemTable(int64_t threshold, int32_t lineno, chpl_string filename) {
  const int numberWidth   = 9;
  const int precision     = sizeof(uintptr_t) * 2;
  const int addressWidth  = precision + 4;
  const int descWidth     = 80-3*numberWidth-addressWidth;
  int filenameWidth       = strlen("Allocated Memory (Bytes)");
  int totalWidth;

  memTableEntry* memEntry;
  int n, i;
  char* loc;
  memTableEntry** table;

  if (!memtrack)
    chpl_error("The printMemTable function only works with the --memtrack flag", lineno, filename);

  n = 0;
  filenameWidth = strlen("Allocated Memory (Bytes)");
  for (i = 0; i < HASHSIZE; i++) {
    for (memEntry = memTable[i]; memEntry != NULL; memEntry = memEntry->nextInBucket) {
      size_t chunk = memEntry->number * memEntry->size;
      if (chunk >= threshold) {
        n += 1;
        if (memEntry->filename) {
          int filenameLength = strlen(memEntry->filename);
          if (filenameLength > filenameWidth)
            filenameWidth = filenameLength;
        }
      }
    }
  }

  totalWidth = filenameWidth+numberWidth*4+descWidth+addressWidth;
  for (i = 0; i < totalWidth; i++)
    printf("=");
  printf("\n");
  printf("%-*s%-*s%-*s%-*s%-*s%-*s\n",
         filenameWidth+numberWidth, "Allocated Memory (Bytes)",
         numberWidth, "Number",
         numberWidth, "Size",
         numberWidth, "Total",
         descWidth, "Description",
         addressWidth, "Address");
  for (i = 0; i < totalWidth; i++)
    printf("=");
  printf("\n");

  table = (memTableEntry**)malloc(n*sizeof(memTableEntry*));
  if (!table)
    chpl_error("out of memory printing memory table", lineno, filename);

  n = 0;
  for (i = 0; i < HASHSIZE; i++) {
    for (memEntry = memTable[i]; memEntry != NULL; memEntry = memEntry->nextInBucket) {
      size_t chunk = memEntry->number * memEntry->size;
      if (chunk >= threshold) {
        table[n++] = memEntry;
      }
    }
  }
  qsort(table, n, sizeof(memTableEntry*), descCmp);

  loc = (char*)malloc((filenameWidth+numberWidth+1)*sizeof(char));

  for (i = 0; i < n; i++) {
    memEntry = table[i];
    if (memEntry->filename)
      sprintf(loc, "%s:%d", memEntry->filename, memEntry->lineno);
    else
      sprintf(loc, "--");
    printf("%-*s%-*zu%-*zu%-*zu%-*s%#-*.*" PRIxPTR "\n",
           filenameWidth+numberWidth, loc,
           numberWidth, memEntry->number,
           numberWidth, memEntry->size,
           numberWidth, memEntry->size*memEntry->number,
           descWidth, chpl_memDescString(memEntry->description),
           addressWidth, precision, (uintptr_t)memEntry->memAlloc);
  }
  for (i = 0; i < totalWidth; i++)
    printf("=");
  printf("\n");
  putchar('\n');

  free(table);
  free(loc);
}


static memTableEntry* lookupMemory(void* memAlloc) {
  memTableEntry* found = NULL;
  PRINTF("");
  chpl_mutex_lock(&memtrack_lock);

  found = lookupMemoryNoLock(memAlloc);

  chpl_mutex_unlock(&memtrack_lock);
  PRINTF(" done");
  return found;
}


static void installMemory(void* memAlloc, size_t number, size_t size, chpl_memDescInt_t description, int32_t lineno, chpl_string filename) {
  unsigned hashValue;
  memTableEntry* memEntry;
  PRINTF("");
  chpl_mutex_lock(&memtrack_lock);
  memEntry = lookupMemoryNoLock(memAlloc);

  if (!memEntry) {
    memEntry = (memTableEntry*) calloc(1, sizeof(memTableEntry));
    if (!memEntry) {
      char* message = chpl_glom_strings(3, "Out of memory allocating table entry for \"",
                                        chpl_memDescString(description), "\"");
      chpl_error(message, lineno, filename);
    }

    hashValue = hash(memAlloc);
    memEntry->nextInBucket = memTable[hashValue];
    memTable[hashValue] = memEntry;

    memEntry->description = description;
    memEntry->memAlloc = memAlloc;
    memEntry->lineno = lineno;
    memEntry->filename = filename;
  }
  memEntry->number = number;
  memEntry->size = size;
  chpl_mutex_unlock(&memtrack_lock);
  PRINTF(" done");
}


static void updateMemory(memTableEntry* memEntry, void* oldAddress, void* newAddress,
                         size_t number, size_t size) {
  unsigned newHashValue;
  PRINTF("");
  chpl_mutex_lock(&memtrack_lock);
  newHashValue = hash(newAddress);

  /* Rehash on the new memory location.  */
  removeBucketEntry(oldAddress);
  memEntry->nextInBucket = memTable[newHashValue];
  memTable[newHashValue] = memEntry;

  memEntry->memAlloc = newAddress;
  memEntry->number = number;
  memEntry->size = size;
  chpl_mutex_unlock(&memtrack_lock);
  PRINTF(" done");
}

static void removeMemory(void* memAlloc, int32_t lineno, chpl_string filename) {
  memTableEntry* thisBucketEntry;
  memTableEntry* memEntry;
  PRINTF("");
  chpl_mutex_lock(&memtrack_lock);
  memEntry = lookupMemoryNoLock(memAlloc);

  if (memEntry) {
    /* Remove the entry from the bucket list. */
    thisBucketEntry = removeBucketEntry(memAlloc);
    free(thisBucketEntry);
  } else {
    chpl_error("Attempting to free memory that wasn't allocated", lineno, filename);
  }
  PRINTF(" done");
  chpl_mutex_unlock(&memtrack_lock);
}


static void printToMemLog(const char* memType, size_t number, size_t size,
                          chpl_memDescInt_t description,
                          int32_t lineno, chpl_string filename,
                          void* memAlloc, void* moreMemAlloc) {
#ifndef LAUNCHER
  size_t chunk = number * size;
  chpl_mutex_lock(&memtrace_lock);
  if (chunk >= memthresholdValue) {
    if (moreMemAlloc && (moreMemAlloc != memAlloc)) {
      fprintf(memlog, "%s called at %s:%"PRId32" on locale %"PRId32" for %zu items of size %zu for %s:  0x%p -> 0x%p\n",
              memType, filename, lineno, chpl_localeID, number, size, chpl_memDescString(description),
              memAlloc, moreMemAlloc);
    } else {
      fprintf(memlog, "%s called at %s:%"PRId32" on locale %"PRId32" for %zu items of size %zu for %s:  %p\n",
              memType, filename, lineno, chpl_localeID, number, size, chpl_memDescString(description), memAlloc);
    }
  }
  chpl_mutex_unlock(&memtrace_lock);
#endif
}


void
chpl_startMemDiagnosis() {
  memDiagnosisFlag = 1;
}


void
chpl_stopMemDiagnosis() {
  memDiagnosisFlag = 0;
}


void chpl_track_malloc(void* memAlloc, size_t chunk, size_t number, size_t size, chpl_memDescInt_t description, int32_t lineno, chpl_string filename) {
  if (memtrace && (!MEM_DIAGNOSIS || memDiagnosisFlag)) {
    printToMemLog("malloc", number, size, description,
                  lineno, filename, memAlloc, NULL);
  }
  if (memtrack) {
    installMemory(memAlloc, number, size, description, lineno, filename);
    if (memstat) {
      increaseMemStat(chunk, lineno, filename);
    }
  }
}


void chpl_track_free(void* memAlloc, int32_t lineno, chpl_string filename) {
  if (memtrace) {
    if (memtrack) {
      memTableEntry* memEntry;
      memEntry = lookupMemory(memAlloc);
      if (!MEM_DIAGNOSIS || memDiagnosisFlag)
        printToMemLog("free", memEntry->number, memEntry->size,
                      memEntry->description, lineno, filename,
                      memAlloc, NULL);
    } else if (!MEM_DIAGNOSIS || memDiagnosisFlag)
      printToMemLog("free", 0, 0, CHPL_RT_MD_UNKNOWN, lineno,
                    filename, memAlloc, NULL);
  }

  if (memtrack) {
    if (memstat) {
      memTableEntry* memEntry = lookupMemory(memAlloc);
      if (memEntry)
        decreaseMemStat(memEntry->number * memEntry->size);
    }
    removeMemory(memAlloc, lineno, filename);
  }
}


void* chpl_track_realloc1(void* memAlloc, size_t number, size_t size, chpl_memDescInt_t description, int32_t lineno, chpl_string filename) {
  memTableEntry* memEntry = 0;
  if (memtrack && memAlloc != NULL) {
    memEntry = lookupMemory(memAlloc);
    if (!memEntry)
      chpl_error(chpl_glom_strings(3, "Attempting to realloc memory for ",
                                   chpl_memDescString(description), " that wasn't allocated"),
                 lineno, filename);
  }
  return memEntry;
}


void chpl_track_realloc2(void* memEntryV, void* moreMemAlloc, size_t newChunk, void* memAlloc, size_t number, size_t size, chpl_memDescInt_t description, int32_t lineno, chpl_string filename) {
  memTableEntry* memEntry = (memTableEntry*)memEntryV;
  if (memtrack) { 
    if (memAlloc != NULL) {
      if (memEntry) {
        if (memstat)
          decreaseMemStat(memEntry->number * memEntry->size);
        updateMemory(memEntry, memAlloc, moreMemAlloc, number, size);
      }
    } else
      installMemory(moreMemAlloc, number, size, description, lineno, filename);
    if (memstat)
      increaseMemStat(newChunk, lineno, filename);
  }
  if (memtrace && (!MEM_DIAGNOSIS || memDiagnosisFlag)) {
    printToMemLog("realloc", number, size, description, lineno, filename,
                  memAlloc, moreMemAlloc);
  }
}
