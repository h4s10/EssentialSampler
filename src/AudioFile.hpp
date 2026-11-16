#pragma once
#include "Engine.hpp"
namespace hasio {
std::shared_ptr<Sample> loadAudioFile(const std::string& path, std::string& error);
}
