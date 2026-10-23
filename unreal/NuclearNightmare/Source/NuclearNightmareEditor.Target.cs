using UnrealBuildTool;

// Editor target only: the project's code is the editor-only asset generator (NNCoreGen), never cooked or shipped.
public class NuclearNightmareEditorTarget : TargetRules
{
	public NuclearNightmareEditorTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Editor;
		DefaultBuildSettings = BuildSettingsVersion.V5;
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_6;
		ExtraModuleNames.Add("NNCoreGen");
	}
}
