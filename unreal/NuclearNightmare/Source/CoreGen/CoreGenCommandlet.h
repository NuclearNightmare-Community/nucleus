#pragma once

#include "Commandlets/Commandlet.h"
#include "CoreGenCommandlet.generated.h"

/**
 * Builds core's Blueprint assets from code, so they are reproducible and reviewable as source.
 * Run: UnrealEditor-Cmd.exe NuclearNightmare.uproject -run=CoreGen -CoreName=<mod.json name>
 * Writes /Game/Mods/<CoreName>/ModActor, WBP_<CoreName>Text and WBP_<CoreName>Panel (story 14).
 * The generated assets reference engine classes only, never this module.
 */
UCLASS()
class UCoreGenCommandlet : public UCommandlet
{
	GENERATED_BODY()

public:
	UCoreGenCommandlet();
	virtual int32 Main(const FString& Params) override;
};
