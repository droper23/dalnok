// VST3 interface identifiers used by the host (definitions only; the values are in the MIT headers).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include "pluginterfaces/base/funknown.cpp"
#include "pluginterfaces/base/coreiids.cpp"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstattributes.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/gui/iplugview.h"
namespace Steinberg {
DEF_CLASS_IID(IPlugView)
DEF_CLASS_IID(IPlugFrame)
}
namespace Steinberg::Vst {
DEF_CLASS_IID(IComponent)
DEF_CLASS_IID(IAudioProcessor)
DEF_CLASS_IID(IEventList)
DEF_CLASS_IID(IHostApplication)
DEF_CLASS_IID(IParameterChanges)
DEF_CLASS_IID(IParamValueQueue)
DEF_CLASS_IID(IMessage)
DEF_CLASS_IID(IAttributeList)
DEF_CLASS_IID(IProcessContextRequirements)
DEF_CLASS_IID(IEditController)
DEF_CLASS_IID(IComponentHandler)
DEF_CLASS_IID(IComponentHandler2)
DEF_CLASS_IID(IConnectionPoint)
}
#pragma clang diagnostic pop
