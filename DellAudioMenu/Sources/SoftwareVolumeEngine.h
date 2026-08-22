#ifndef SoftwareVolumeEngine_h
#define SoftwareVolumeEngine_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *DAVolumeEngineRef;

OSStatus DAVolumeEngineCreate(
	AudioObjectID inputDeviceID,
	AudioObjectID outputDeviceID,
	DAVolumeEngineRef *outEngine);
OSStatus DAVolumeEngineStart(DAVolumeEngineRef engine);
void DAVolumeEngineStop(DAVolumeEngineRef engine);
void DAVolumeEngineDestroy(DAVolumeEngineRef engine);
void DAVolumeEngineSetGain(DAVolumeEngineRef engine, Float32 gain);
bool DAVolumeEngineIsRunning(DAVolumeEngineRef engine);
uint64_t DAVolumeEngineCallbackCount(DAVolumeEngineRef engine);
uint64_t DAVolumeEngineNonSilentFrameCount(DAVolumeEngineRef engine);
Float32 DAVolumeEngineInputPeak(DAVolumeEngineRef engine);
Float32 DAVolumeEngineOutputPeak(DAVolumeEngineRef engine);

#ifdef __cplusplus
}
#endif

#endif
