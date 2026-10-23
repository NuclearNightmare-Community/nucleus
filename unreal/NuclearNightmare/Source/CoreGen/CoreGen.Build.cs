using UnrealBuildTool;

public class CoreGen : ModuleRules
{
	public CoreGen(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
		PrivateDependencyModuleNames.AddRange(new[]
		{
			"Core", "CoreUObject", "Engine", "UnrealEd", "AssetRegistry",
			"BlueprintGraph", "Kismet", "KismetCompiler",
			"UMG", "UMGEditor", "Slate", "SlateCore",
		});
	}
}
