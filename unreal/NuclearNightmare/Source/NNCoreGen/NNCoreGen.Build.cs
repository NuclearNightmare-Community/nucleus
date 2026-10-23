using UnrealBuildTool;

public class NNCoreGen : ModuleRules
{
	public NNCoreGen(ReadOnlyTargetRules Target) : base(Target)
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
