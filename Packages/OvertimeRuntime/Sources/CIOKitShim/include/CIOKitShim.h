#pragma once

#include <stdint.h>
#include <mach/mach.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPM.h>

static const uint32_t OTMessageCanSystemSleep = kIOMessageCanSystemSleep;
static const uint32_t OTMessageSystemWillSleep = kIOMessageSystemWillSleep;
static const uint32_t OTMessageSystemWillNotSleep = kIOMessageSystemWillNotSleep;
static const uint32_t OTMessageSystemWillPowerOn = kIOMessageSystemWillPowerOn;
static const uint32_t OTMessageSystemHasPoweredOn = kIOMessageSystemHasPoweredOn;
static const uint32_t OTPMMessageClamshellStateChange = kIOPMMessageClamshellStateChange;
static const uint32_t OTPMMessageSystemPowerEventOccurred = kIOPMMessageSystemPowerEventOccurred;
static const uint32_t OTClamshellStateBit = kClamshellStateBit;
static const uint32_t OTClamshellSleepBit = kClamshellSleepBit;

static inline mach_port_t OTTaskSelf(void) { return mach_task_self(); }
