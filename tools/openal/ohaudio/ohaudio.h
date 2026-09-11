#ifndef BACKENDS_OHAUDIO_H
#define BACKENDS_OHAUDIO_H

#include "base.h"

#include <string>
#include <vector>

struct OHAudioBackendFactory final : public BackendFactory {
public:
    bool init() override;

    bool querySupport(BackendType type) override;

    std::vector<std::string> enumerate(BackendType type) override;

    BackendPtr createBackend(DeviceBase *device, BackendType type) override;

    static BackendFactory &getFactory();
};

#endif /* BACKENDS_OHAUDIO_H */
