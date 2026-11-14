#include "CoreGenCommandlet.h"

#include "AssetRegistry/AssetRegistryModule.h"
#include "Blueprint/SlateBlueprintLibrary.h"
#include "Blueprint/UserWidget.h"
#include "Blueprint/WidgetBlueprintGeneratedClass.h"
#include "Blueprint/WidgetBlueprintLibrary.h"
#include "Blueprint/WidgetTree.h"
#include "Components/BillboardComponent.h"
#include "Components/Border.h"
#include "Components/Button.h"
#include "Components/ButtonSlot.h"
#include "Components/BorderSlot.h"
#include "Components/CanvasPanel.h"
#include "Components/HorizontalBox.h"
#include "Components/HorizontalBoxSlot.h"
#include "Components/Image.h"
#include "Components/Overlay.h"
#include "Components/OverlaySlot.h"
#include "Components/ScrollBox.h"
#include "Components/SizeBox.h"
#include "Components/SizeBoxSlot.h"
#include "Components/SkeletalMeshComponent.h"
#include "Components/Spacer.h"
#include "Components/StaticMeshComponent.h"
#include "Components/TextBlock.h"
#include "Components/VerticalBox.h"
#include "Components/Widget.h"
#include "EdGraphSchema_K2.h"
#include "Engine/Blueprint.h"
#include "Engine/BlueprintGeneratedClass.h"
#include "Engine/CollisionProfile.h"
#include "Engine/SCS_Node.h"
#include "Engine/SimpleConstructionScript.h"
#include "Engine/StaticMesh.h"
#include "Engine/Texture2D.h"
#include "Engine/UserDefinedEnum.h"
#include "ImageCore.h"
#include "ImageUtils.h"
#include "GameFramework/Actor.h"
#include "GameFramework/PlayerStart.h"
#include "K2Node_CallFunction.h"
#include "K2Node_ComponentBoundEvent.h"
#include "K2Node_Event.h"
#include "K2Node_FunctionEntry.h"
#include "K2Node_FunctionResult.h"
#include "K2Node_MakeStruct.h"
#include "K2Node_VariableGet.h"
#include "K2Node_VariableSet.h"
#include "Kismet/KismetMathLibrary.h"
#include "Kismet/KismetStringLibrary.h"
#include "Kismet/KismetTextLibrary.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/CompilerResultsLog.h"
#include "Kismet2/EnumEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "Materials/MaterialInterface.h"
#include "Misc/FileHelper.h"
#include "Misc/PackageName.h"
#include "Misc/Paths.h"
#include "UObject/EnumProperty.h"
#include "UObject/SavePackage.h"
#include "WidgetBlueprint.h"

DEFINE_LOG_CATEGORY_STATIC(LogCoreGen, Log, All);

namespace
{
	const FName PN_Then = UEdGraphSchema_K2::PN_Then;
	const FName PN_Exec = UEdGraphSchema_K2::PN_Execute;
	const FName PN_Self = UEdGraphSchema_K2::PN_Self;
	const FName PN_Ret = UEdGraphSchema_K2::PN_ReturnValue;

	FEdGraphPinType PinType(FName Category, UObject* Sub = nullptr)
	{
		FEdGraphPinType T;
		T.PinCategory = Category;
		T.PinSubCategoryObject = Sub;
		return T;
	}
	FEdGraphPinType StrT() { return PinType(UEdGraphSchema_K2::PC_String); }
	/** A Blueprint "Float" (UE5: real, double precision); Lua numbers pass straight in. */
	FEdGraphPinType RealT()
	{
		FEdGraphPinType T = PinType(UEdGraphSchema_K2::PC_Real);
		T.PinSubCategory = UEdGraphSchema_K2::PC_Double;
		return T;
	}
	FEdGraphPinType Vec2T() { return PinType(UEdGraphSchema_K2::PC_Struct, TBaseStructure<FVector2D>::Get()); }
	FEdGraphPinType ObjT(UClass* C) { return PinType(UEdGraphSchema_K2::PC_Object, C); }
	FEdGraphPinType BoolT() { return PinType(UEdGraphSchema_K2::PC_Boolean); }
	FEdGraphPinType IntT() { return PinType(UEdGraphSchema_K2::PC_Int); }

	using FParams = TArray<TPair<FName, FEdGraphPinType>>;

	/** Places nodes left to right in one graph and wires them. Any missing pin is a generator bug, so it asserts. */
	struct FGraph
	{
		UBlueprint* BP;
		UEdGraph* G;
		const UEdGraphSchema_K2* K2 = GetDefault<UEdGraphSchema_K2>();
		int32 X = 0;

		FGraph(UBlueprint* InBP, UEdGraph* InG) : BP(InBP), G(InG) {}

		void Place(UEdGraphNode* N) { N->NodePosX = X; N->NodePosY = 0; X += 320; }

		/** A call to a function of the Blueprint itself (one added with AddFunction). */
		UK2Node_CallFunction* CallSelf(FName Fn)
		{
			FGraphNodeCreator<UK2Node_CallFunction> C(*G);
			UK2Node_CallFunction* N = C.CreateNode(false);
			N->FunctionReference.SetSelfMember(Fn);
			Place(N);
			C.Finalize();
			return N;
		}

		UK2Node_CallFunction* Call(UClass* Owner, FName Fn)
		{
			UFunction* F = Owner->FindFunctionByName(Fn);
			checkf(F, TEXT("No function %s on %s"), *Fn.ToString(), *Owner->GetName());
			FGraphNodeCreator<UK2Node_CallFunction> C(*G);
			UK2Node_CallFunction* N = C.CreateNode(false);
			N->SetFromFunction(F);
			Place(N);
			C.Finalize();
			return N;
		}

		UK2Node_VariableSet* Set(FName Var)
		{
			FGraphNodeCreator<UK2Node_VariableSet> C(*G);
			UK2Node_VariableSet* N = C.CreateNode(false);
			N->VariableReference.SetSelfMember(Var);
			Place(N);
			C.Finalize();
			return N;
		}

		UK2Node_VariableGet* Get(FName Var)
		{
			FGraphNodeCreator<UK2Node_VariableGet> C(*G);
			UK2Node_VariableGet* N = C.CreateNode(false);
			N->VariableReference.SetSelfMember(Var);
			Place(N);
			C.Finalize();
			return N;
		}

		/** A Make <Struct> node; its input pins are named after the struct's members. */
		UK2Node_MakeStruct* MakeStruct(UScriptStruct* Struct)
		{
			FGraphNodeCreator<UK2Node_MakeStruct> C(*G);
			UK2Node_MakeStruct* N = C.CreateNode(false);
			N->StructType = Struct;
			Place(N);
			C.Finalize();
			return N;
		}

		/** The node's one data output pin (a Make <Struct> node names it after the struct). */
		UEdGraphPin* OnlyOutput(UEdGraphNode* N)
		{
			UEdGraphPin* Found = nullptr;
			for (UEdGraphPin* P : N->Pins)
			{
				if (P->Direction == EGPD_Output && P->PinType.PinCategory != UEdGraphSchema_K2::PC_Exec)
				{
					checkf(!Found, TEXT("More than one output pin on %s"), *N->GetNodeTitle(ENodeTitleType::ListView).ToString());
					Found = P;
				}
			}
			checkf(Found, TEXT("No output pin on %s"), *N->GetNodeTitle(ENodeTitleType::ListView).ToString());
			return Found;
		}

		UEdGraphPin* Pin(UEdGraphNode* N, FName Name)
		{
			UEdGraphPin* P = N->FindPin(Name);
			checkf(P, TEXT("No pin %s on %s"), *Name.ToString(), *N->GetNodeTitle(ENodeTitleType::ListView).ToString());
			return P;
		}

		void Link(UEdGraphPin* A, UEdGraphPin* B)
		{
			const bool bOk = K2->TryCreateConnection(A, B);
			checkf(bOk, TEXT("Cannot connect %s -> %s"), *A->GetName(), *B->GetName());
		}
		void Link(UEdGraphNode* A, FName APin, UEdGraphNode* B, FName BPin) { Link(Pin(A, APin), Pin(B, BPin)); }

		/** Wires the exec pins of the given nodes in order, skipping pure nodes. */
		void Chain(std::initializer_list<UEdGraphNode*> Nodes)
		{
			UEdGraphNode* Prev = nullptr;
			for (UEdGraphNode* N : Nodes)
			{
				const bool bHasIn = N->FindPin(PN_Exec) != nullptr;
				const bool bHasOut = N->FindPin(PN_Then) != nullptr;
				if (!bHasIn && !bHasOut)
				{
					continue;
				}
				if (Prev && bHasIn)
				{
					Link(Prev, PN_Then, N, PN_Exec);
				}
				Prev = bHasOut ? N : nullptr;
			}
		}

		void Default(UEdGraphNode* N, FName PinName, const FString& Value) { K2->TrySetDefaultValue(*Pin(N, PinName), Value); }
	};

	struct FFunc
	{
		UEdGraph* G = nullptr;
		UK2Node_FunctionEntry* Entry = nullptr;
		UK2Node_FunctionResult* Result = nullptr;
	};

	FFunc AddFunction(UBlueprint* BP, FName Name, const FParams& In, const FParams& Out)
	{
		FFunc F;
		F.G = FBlueprintEditorUtils::CreateNewGraph(BP, Name, UEdGraph::StaticClass(), UEdGraphSchema_K2::StaticClass());
		FBlueprintEditorUtils::AddFunctionGraph<UClass>(BP, F.G, /*bIsUserCreated*/ true, static_cast<UClass*>(nullptr));
		TArray<UK2Node_FunctionEntry*> Entries;
		F.G->GetNodesOfClass(Entries);
		check(Entries.Num() == 1);
		F.Entry = Entries[0];
		for (const auto& P : In)
		{
			F.Entry->CreateUserDefinedPin(P.Key, P.Value, EGPD_Output, false);
		}
		if (Out.Num() > 0)
		{
			FGraphNodeCreator<UK2Node_FunctionResult> C(*F.G);
			F.Result = C.CreateNode(false);
			F.Result->FunctionReference = F.Entry->FunctionReference;
			F.Result->NodePosX = 1600;
			C.Finalize();
			for (const auto& P : Out)
			{
				F.Result->CreateUserDefinedPin(P.Key, P.Value, EGPD_Input, false);
			}
		}
		return F;
	}

	void ClearGraph(UBlueprint* BP, UEdGraph* G)
	{
		// New Blueprints come with disabled placeholder events (BeginPlay, Tick...); start from an empty graph.
		for (UEdGraphNode* N : TArray<UEdGraphNode*>(G->Nodes))
		{
			FBlueprintEditorUtils::RemoveNode(BP, N, /*bDontRecompile*/ true);
		}
	}

	bool Compile(UBlueprint* BP)
	{
		FCompilerResultsLog Results;
		FKismetEditorUtilities::CompileBlueprint(BP, EBlueprintCompileOptions::SkipGarbageCollection, &Results);
		for (const TSharedRef<FTokenizedMessage>& M : Results.Messages)
		{
			UE_LOG(LogCoreGen, Display, TEXT("  [%s] %s"), *BP->GetName(), *M->ToText().ToString());
		}
		if (BP->Status == BS_Error || Results.NumErrors > 0)
		{
			UE_LOG(LogCoreGen, Error, TEXT("%s failed to compile (%d errors)"), *BP->GetPathName(), Results.NumErrors);
			return false;
		}
		return true;
	}

	bool Save(UObject* BP)
	{
		UPackage* Pkg = BP->GetOutermost();
		FAssetRegistryModule::AssetCreated(BP);
		Pkg->MarkPackageDirty();
		const FString File = FPackageName::LongPackageNameToFilename(Pkg->GetName(), FPackageName::GetAssetPackageExtension());
		FSavePackageArgs Args;
		Args.TopLevelFlags = RF_Public | RF_Standalone;
		const bool bOk = UPackage::SavePackage(Pkg, BP, *File, Args);
		UE_LOG(LogCoreGen, Display, TEXT("%s %s -> %s"), bOk ? TEXT("Saved") : TEXT("FAILED to save"), *Pkg->GetName(), *File);
		return bOk;
	}

	UBlueprint* NewBlueprint(const FString& LongName, UClass* Parent, TSubclassOf<UBlueprint> BPClass, TSubclassOf<UBlueprintGeneratedClass> GenClass)
	{
		UPackage* Pkg = CreatePackage(*LongName);
		Pkg->FullyLoad();
		return FKismetEditorUtilities::CreateBlueprint(Parent, Pkg, FName(FPackageName::GetShortName(LongName)), BPTYPE_Normal, BPClass, GenClass, TEXT("CoreGen"));
	}

	// ---------------------------------------------------------------- story 2 (Mod Manager v1): the game look's setters
	// Lua passes only objects (a font, a material, loaded by path at runtime: nothing of the game's is cooked in) and
	// numbers; the structs are made here.

	FEdGraphPinType LinearColorT() { return PinType(UEdGraphSchema_K2::PC_Struct, TBaseStructure<FLinearColor>::Get()); }
	const TCHAR* WhiteColor = TEXT("(R=1.000000,G=1.000000,B=1.000000,A=1.000000)");

	/** MakeColor(R, G, B, A) fed from four entry pins (names Prefix + R/G/B/A); returns the node. */
	UK2Node_CallFunction* ColorFrom(FGraph& G, UEdGraphNode* Entry, const FString& Prefix)
	{
		UK2Node_CallFunction* Make = G.Call(UKismetMathLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetMathLibrary, MakeColor));
		for (const TCHAR* Ch : {TEXT("R"), TEXT("G"), TEXT("B"), TEXT("A")})
		{
			G.Link(Entry, FName(Prefix + Ch), Make, FName(Ch));
		}
		return Make;
	}
	/** MakeColor(R, G, B) constants and A from one entry pin. */
	UK2Node_CallFunction* ColorAlphaFrom(FGraph& G, UEdGraphNode* Entry, FName APin, const TCHAR* R, const TCHAR* Gr, const TCHAR* B)
	{
		UK2Node_CallFunction* Make = G.Call(UKismetMathLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetMathLibrary, MakeColor));
		G.Default(Make, TEXT("R"), R);
		G.Default(Make, TEXT("G"), Gr);
		G.Default(Make, TEXT("B"), B);
		G.Link(Entry, APin, Make, TEXT("A"));
		return Make;
	}
	/** A Make SlateColor whose SpecifiedColor is the given colour pin; returns its output pin. */
	UEdGraphPin* SlateColorOf(FGraph& G, UEdGraphPin* LinearColor)
	{
		UK2Node_MakeStruct* Color = G.MakeStruct(FSlateColor::StaticStruct());
		G.Link(LinearColor, G.Pin(Color, FName(TEXT("SpecifiedColor"))));
		return G.OnlyOutput(Color);
	}
	/** A Make SlateFontInfo with FontObject and Size from two pins (every other member at its default); its output pin. */
	UEdGraphPin* FontInfoOf(FGraph& G, UEdGraphPin* Font, UEdGraphPin* Size)
	{
		UK2Node_MakeStruct* Info = G.MakeStruct(FSlateFontInfo::StaticStruct());
		G.Link(Font, G.Pin(Info, GET_MEMBER_NAME_CHECKED(FSlateFontInfo, FontObject)));
		G.Link(Size, G.Pin(Info, GET_MEMBER_NAME_CHECKED(FSlateFontInfo, Size)));
		return G.OnlyOutput(Info);
	}
	/** UWidgetBlueprintLibrary::MakeBrushFromMaterial(Material pin, 32, 32); its output pin. */
	UEdGraphPin* MaterialBrushOf(FGraph& G, UEdGraphPin* Material)
	{
		UK2Node_CallFunction* Make = G.Call(UWidgetBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidgetBlueprintLibrary, MakeBrushFromMaterial));
		G.Link(Material, G.Pin(Make, TEXT("Material")));
		return G.Pin(Make, PN_Ret);
	}

	/**
	 * SetBackgroundMaterial(Material: MaterialInterface, R, G, B, A, Padding: Float) and SetBackgroundSolid() on a widget
	 * with a Border "Background": the material brush tinted by the Border's brush colour, with the same padding all
	 * round; Solid puts back the default brush (a solid quad, the Border's starting brush) for a plain style.
	 */
	struct FMaterialFns { FFunc Mat; FFunc Solid; };
	FMaterialFns AddBackgroundMaterial(UBlueprint* BP)
	{
		FMaterialFns F;
		F.Mat = AddFunction(BP, TEXT("SetBackgroundMaterial"), {{TEXT("Material"), ObjT(UMaterialInterface::StaticClass())},
			{TEXT("R"), RealT()}, {TEXT("G"), RealT()}, {TEXT("B"), RealT()}, {TEXT("A"), RealT()}, {TEXT("Padding"), RealT()}}, {});
		F.Solid = AddFunction(BP, TEXT("SetBackgroundSolid"), {}, {});
		return F;
	}
	void FillBackgroundMaterial(UBlueprint* BP, const FMaterialFns& F)
	{
		{
			FGraph G(BP, F.Mat.G);
			UK2Node_VariableGet* GetBg = G.Get(TEXT("Background"));
			UEdGraphPin* Brush = MaterialBrushOf(G, G.Pin(F.Mat.Entry, TEXT("Material")));
			UK2Node_CallFunction* SetBrush = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetBrush));
			G.Link(GetBg, TEXT("Background"), SetBrush, PN_Self);
			G.Link(Brush, G.Pin(SetBrush, TEXT("InBrush")));
			UK2Node_CallFunction* Make = ColorFrom(G, F.Mat.Entry, TEXT(""));
			UK2Node_CallFunction* SetColor = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetBrushColor));
			G.Link(GetBg, TEXT("Background"), SetColor, PN_Self);
			G.Link(Make, PN_Ret, SetColor, TEXT("InBrushColor"));
			UK2Node_MakeStruct* Margin = G.MakeStruct(FMargin::StaticStruct());
			for (const FName Side : {GET_MEMBER_NAME_CHECKED(FMargin, Left), GET_MEMBER_NAME_CHECKED(FMargin, Top),
			                         GET_MEMBER_NAME_CHECKED(FMargin, Right), GET_MEMBER_NAME_CHECKED(FMargin, Bottom)})
			{
				G.Link(F.Mat.Entry, TEXT("Padding"), Margin, Side);
			}
			UK2Node_CallFunction* SetPad = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetPadding));
			G.Link(GetBg, TEXT("Background"), SetPad, PN_Self);
			G.Link(G.OnlyOutput(Margin), G.Pin(SetPad, TEXT("InPadding")));
			G.Chain({F.Mat.Entry, SetBrush, SetColor, SetPad});
		}
		{
			FGraph G(BP, F.Solid.G);
			UK2Node_VariableGet* GetBg = G.Get(TEXT("Background"));
			UK2Node_MakeStruct* Brush = G.MakeStruct(FSlateBrush::StaticStruct());
			UK2Node_CallFunction* SetBrush = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetBrush));
			G.Link(GetBg, TEXT("Background"), SetBrush, PN_Self);
			G.Link(G.OnlyOutput(Brush), G.Pin(SetBrush, TEXT("InBrush")));
			G.Chain({F.Solid.Entry, SetBrush});
		}
	}

	/** A Border "Background" (alpha 0, padding 0, self-hit-test-invisible) as the root of a widget tree; returns it. */
	UBorder* RootBackground(UWidgetTree* T)
	{
		UBorder* Background = T->ConstructWidget<UBorder>(UBorder::StaticClass(), TEXT("Background"));
		Background->SetBrushColor(FLinearColor(0.f, 0.f, 0.f, 0.f));
		Background->SetPadding(FMargin(0.f));
		Background->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		Background->bIsVariable = true;
		return Background;
	}

	/**
	 * WBP_<Core>Text: Border "Background" -> TextBlock "Text" (white, drop shadow, size 18), and three functions:
	 *   SetText(NewText: String)                  Text.SetText(NewText)
	 *   SetBackground(R, G, B, A: Float)          Background.SetBrushColor((R, G, B, A)); A = 0 shows no box
	 *   SetBackgroundPadding(Padding: Float)      Background.SetPadding(Padding on all four sides)
	 * Story 2 (Mod Manager v1, the game look; Lua passes objects loaded by path and numbers):
	 *   SetFontObject(Font: Object, Size: Float)             Text.SetFont(FontInfo(Font, Size))
	 *   SetTextColor(R, G, B, A, ShadowA: Float)             text colour (R, G, B, A), shadow colour (0, 0, 0, ShadowA)
	 *   SetBackgroundMaterial(Material, R, G, B, A, Padding) Background brush from the material, its tint, padding
	 *   SetBackgroundSolid()                                 Background brush back to the default solid quad
	 * The Border is hit-test invisible and starts at alpha 0 with padding 0, so an unstyled element looks and measures
	 * exactly like the bare TextBlock it replaces. Lua creates it, parents it into a game canvas and calls these; it
	 * carries no logic of its own.
	 *
	 * Story 8 names the padding function SetPadding. UUserWidget already has a native SetPadding(FMargin) (padding
	 * outside the root widget), so a Blueprint function of that name would collide with it; it is SetBackgroundPadding.
	 */
	UWidgetBlueprint* BuildText(const FString& Dir, const FString& Core)
	{
		UWidgetBlueprint* WBP = CastChecked<UWidgetBlueprint>(NewBlueprint(Dir / FString::Printf(TEXT("WBP_%sText"), *Core),
			UUserWidget::StaticClass(), UWidgetBlueprint::StaticClass(), UWidgetBlueprintGeneratedClass::StaticClass()));
		for (const TCHAR* Fn : {TEXT("SetText"), TEXT("SetBackground"), TEXT("SetBackgroundPadding"), TEXT("SetFontObject"),
		                        TEXT("SetTextColor"), TEXT("SetBackgroundMaterial"), TEXT("SetBackgroundSolid")})
		{
			// A name the parent class already has would shadow or clash with it: fail loudly here, not in game.
			checkf(!UUserWidget::StaticClass()->FindFunctionByName(Fn), TEXT("UUserWidget already has a function %s"), Fn);
		}

		UWidgetTree* T = WBP->WidgetTree;
		UBorder* Background = T->ConstructWidget<UBorder>(UBorder::StaticClass(), TEXT("Background"));
		Background->SetBrushColor(FLinearColor(0.f, 0.f, 0.f, 0.f));
		Background->SetPadding(FMargin(0.f));
		Background->SetVisibility(ESlateVisibility::HitTestInvisible);
		Background->bIsVariable = true;
		T->RootWidget = Background;

		UTextBlock* Text = T->ConstructWidget<UTextBlock>(UTextBlock::StaticClass(), TEXT("Text"));
		Text->SetText(FText::GetEmpty());
		Text->SetColorAndOpacity(FSlateColor(FLinearColor::White));
		Text->SetShadowOffset(FVector2D(1.f, 1.f));
		Text->SetShadowColorAndOpacity(FLinearColor(0.f, 0.f, 0.f, 0.85f));
		FSlateFontInfo Font = Text->GetFont();
		Font.Size = 18;
		Text->SetFont(Font);
		Text->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		Text->bIsVariable = true;
		UBorderSlot* TextSlot = CastChecked<UBorderSlot>(Background->AddChild(Text));
		TextSlot->SetPadding(FMargin(0.f));
		TextSlot->SetHorizontalAlignment(HAlign_Fill);
		TextSlot->SetVerticalAlignment(VAlign_Fill);
		WBP->OnVariableAdded(TEXT("Background"));
		WBP->OnVariableAdded(TEXT("Text"));

		// The functions need the compiled widget variables, so compile first.
		FFunc SetText = AddFunction(WBP, TEXT("SetText"), {{TEXT("NewText"), StrT()}}, {});
		FFunc SetBg = AddFunction(WBP, TEXT("SetBackground"),
			{{TEXT("R"), RealT()}, {TEXT("G"), RealT()}, {TEXT("B"), RealT()}, {TEXT("A"), RealT()}}, {});
		FFunc SetPad = AddFunction(WBP, TEXT("SetBackgroundPadding"), {{TEXT("Padding"), RealT()}}, {});
		FFunc SetFontObj = AddFunction(WBP, TEXT("SetFontObject"), {{TEXT("Font"), ObjT(UObject::StaticClass())}, {TEXT("Size"), RealT()}}, {});
		FFunc SetColor = AddFunction(WBP, TEXT("SetTextColor"),
			{{TEXT("R"), RealT()}, {TEXT("G"), RealT()}, {TEXT("B"), RealT()}, {TEXT("A"), RealT()}, {TEXT("ShadowA"), RealT()}}, {});
		FMaterialFns Mat = AddBackgroundMaterial(WBP);
		if (!Compile(WBP)) return nullptr;
		FillBackgroundMaterial(WBP, Mat);
		{
			// SetFontObject(Font, Size): Text.SetFont(FontInfo(Font, Size)).
			FGraph G(WBP, SetFontObj.G);
			UK2Node_VariableGet* GetText = G.Get(TEXT("Text"));
			UEdGraphPin* Info = FontInfoOf(G, G.Pin(SetFontObj.Entry, TEXT("Font")), G.Pin(SetFontObj.Entry, TEXT("Size")));
			UK2Node_CallFunction* Set = G.Call(UTextBlock::StaticClass(), GET_FUNCTION_NAME_CHECKED(UTextBlock, SetFont));
			G.Link(GetText, TEXT("Text"), Set, PN_Self);
			G.Link(Info, G.Pin(Set, TEXT("InFontInfo")));
			G.Chain({SetFontObj.Entry, Set});
		}
		{
			// SetTextColor(R, G, B, A, ShadowA): Text colour, then shadow colour (0, 0, 0, ShadowA).
			FGraph G(WBP, SetColor.G);
			UK2Node_VariableGet* GetText = G.Get(TEXT("Text"));
			UK2Node_CallFunction* Make = ColorFrom(G, SetColor.Entry, TEXT(""));
			UK2Node_CallFunction* SetC = G.Call(UTextBlock::StaticClass(), GET_FUNCTION_NAME_CHECKED(UTextBlock, SetColorAndOpacity));
			G.Link(GetText, TEXT("Text"), SetC, PN_Self);
			G.Link(SlateColorOf(G, G.Pin(Make, PN_Ret)), G.Pin(SetC, TEXT("InColorAndOpacity")));
			UK2Node_CallFunction* Shadow = ColorAlphaFrom(G, SetColor.Entry, TEXT("ShadowA"), TEXT("0.0"), TEXT("0.0"), TEXT("0.0"));
			UK2Node_CallFunction* SetS = G.Call(UTextBlock::StaticClass(), GET_FUNCTION_NAME_CHECKED(UTextBlock, SetShadowColorAndOpacity));
			G.Link(GetText, TEXT("Text"), SetS, PN_Self);
			G.Link(Shadow, PN_Ret, SetS, TEXT("InShadowColorAndOpacity"));
			G.Chain({SetColor.Entry, SetC, SetS});
		}
		{
			// SetBackground(R, G, B, A): Background.SetBrushColor(MakeColor(R, G, B, A)).
			FGraph G(WBP, SetBg.G);
			UK2Node_VariableGet* GetBg = G.Get(TEXT("Background"));
			UK2Node_CallFunction* Make = G.Call(UKismetMathLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetMathLibrary, MakeColor));
			G.Link(SetBg.Entry, TEXT("R"), Make, TEXT("R"));
			G.Link(SetBg.Entry, TEXT("G"), Make, TEXT("G"));
			G.Link(SetBg.Entry, TEXT("B"), Make, TEXT("B"));
			G.Link(SetBg.Entry, TEXT("A"), Make, TEXT("A"));
			UK2Node_CallFunction* Set = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetBrushColor));
			G.Link(GetBg, TEXT("Background"), Set, PN_Self);
			G.Link(Make, PN_Ret, Set, TEXT("InBrushColor"));
			G.Chain({SetBg.Entry, Set});
		}
		{
			// SetBackgroundPadding(Padding): Background.SetPadding(Margin(Padding, Padding, Padding, Padding)).
			FGraph G(WBP, SetPad.G);
			UK2Node_VariableGet* GetBg = G.Get(TEXT("Background"));
			UK2Node_MakeStruct* Margin = G.MakeStruct(FMargin::StaticStruct());
			for (const FName Side : {GET_MEMBER_NAME_CHECKED(FMargin, Left), GET_MEMBER_NAME_CHECKED(FMargin, Top),
			                         GET_MEMBER_NAME_CHECKED(FMargin, Right), GET_MEMBER_NAME_CHECKED(FMargin, Bottom)})
			{
				G.Link(SetPad.Entry, TEXT("Padding"), Margin, Side);
			}
			UK2Node_CallFunction* Set = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetPadding));
			G.Link(GetBg, TEXT("Background"), Set, PN_Self);
			G.Link(G.OnlyOutput(Margin), G.Pin(Set, TEXT("InPadding")));
			G.Chain({SetPad.Entry, Set});
		}
		{
			FGraph G(WBP, SetText.G);
			UK2Node_VariableGet* GetText = G.Get(TEXT("Text"));
			UK2Node_CallFunction* ToText = G.Call(UKismetTextLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetTextLibrary, Conv_StringToText));
			G.Link(SetText.Entry, TEXT("NewText"), ToText, TEXT("InString"));
			UK2Node_CallFunction* Set = G.Call(UTextBlock::StaticClass(), GET_FUNCTION_NAME_CHECKED(UTextBlock, SetText));
			G.Link(GetText, TEXT("Text"), Set, PN_Self);
			G.Link(ToText, PN_Ret, Set, TEXT("InText"));
			G.Chain({SetText.Entry, Set});
		}

		if (!Compile(WBP) || !Save(WBP)) return nullptr;
		return WBP;
	}

	/** Fails loudly when a function name would clash with one UUserWidget already has (shadowing it in game). */
	void CheckNames(std::initializer_list<const TCHAR*> Names)
	{
		for (const TCHAR* Fn : Names)
		{
			checkf(!UUserWidget::StaticClass()->FindFunctionByName(Fn), TEXT("UUserWidget already has a function %s"), Fn);
		}
	}

	/** The panel's and the button's SetBackground(R, G, B, A) and SetBackgroundPadding(Padding), as on the text widget. */
	FFunc AddSetBackground(UBlueprint* BP)
	{
		return AddFunction(BP, TEXT("SetBackground"), {{TEXT("R"), RealT()}, {TEXT("G"), RealT()}, {TEXT("B"), RealT()}, {TEXT("A"), RealT()}}, {});
	}
	void FillBackground(UWidgetBlueprint* WBP, const FFunc& SetBg, const FFunc& SetPad)
	{
		{
			FGraph G(WBP, SetBg.G);
			UK2Node_VariableGet* GetBg = G.Get(TEXT("Background"));
			UK2Node_CallFunction* Make = G.Call(UKismetMathLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetMathLibrary, MakeColor));
			G.Link(SetBg.Entry, TEXT("R"), Make, TEXT("R"));
			G.Link(SetBg.Entry, TEXT("G"), Make, TEXT("G"));
			G.Link(SetBg.Entry, TEXT("B"), Make, TEXT("B"));
			G.Link(SetBg.Entry, TEXT("A"), Make, TEXT("A"));
			UK2Node_CallFunction* Set = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetBrushColor));
			G.Link(GetBg, TEXT("Background"), Set, PN_Self);
			G.Link(Make, PN_Ret, Set, TEXT("InBrushColor"));
			G.Chain({SetBg.Entry, Set});
		}
		{
			FGraph G(WBP, SetPad.G);
			UK2Node_VariableGet* GetBg = G.Get(TEXT("Background"));
			UK2Node_MakeStruct* Margin = G.MakeStruct(FMargin::StaticStruct());
			for (const FName Side : {GET_MEMBER_NAME_CHECKED(FMargin, Left), GET_MEMBER_NAME_CHECKED(FMargin, Top),
			                         GET_MEMBER_NAME_CHECKED(FMargin, Right), GET_MEMBER_NAME_CHECKED(FMargin, Bottom)})
			{
				G.Link(SetPad.Entry, TEXT("Padding"), Margin, Side);
			}
			UK2Node_CallFunction* Set = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetPadding));
			G.Link(GetBg, TEXT("Background"), Set, PN_Self);
			G.Link(G.OnlyOutput(Margin), G.Pin(Set, TEXT("InPadding")));
			G.Chain({SetPad.Entry, Set});
		}
	}

	/**
	 * The tag of a panel or a button (stories 14-15): a String variable CoreTag, set by SetTag(NewTag). Not ToolTipText as
	 * on the text widget: a tooltip on a hit-testable widget (a button, or a panel holding one) would show on hover.
	 */
	FFunc AddTag(UBlueprint* BP)
	{
		FBlueprintEditorUtils::AddMemberVariable(BP, TEXT("CoreTag"), StrT(), TEXT(""));
		return AddFunction(BP, TEXT("SetTag"), {{TEXT("NewTag"), StrT()}}, {});
	}
	void FillTag(UBlueprint* BP, const FFunc& SetTag)
	{
		FGraph G(BP, SetTag.G);
		UK2Node_VariableSet* Set = G.Set(TEXT("CoreTag"));
		G.Link(SetTag.Entry, TEXT("NewTag"), Set, TEXT("CoreTag"));
		G.Chain({SetTag.Entry, Set});
	}


	/**
	 * WBP_<Core>Panel (story 14): Border "Background" -> Overlay "Layers" -> [VerticalBox "VBox", HorizontalBox "HBox"].
	 * Lua puts a vertical panel's children into VBox and a horizontal one's into HBox (the other stays empty: zero size),
	 * sets the gap between them as box slot padding, and reorders them by taking them out and adding them back (box
	 * panels only append). Every container is self-hit-test-invisible: a panel never takes a click itself, while buttons
	 * inside it stay clickable. Functions:
	 *   SetBackground(R, G, B, A), SetBackgroundPadding(Padding)   as on the text widget
	 *   SetTag(NewTag: String)                                     CoreTag = NewTag
	 *   SetBackgroundMaterial(Material, R, G, B, A, Padding), SetBackgroundSolid()   story 2, as on the text widget
	 */
	UWidgetBlueprint* BuildPanel(const FString& Dir, const FString& Core)
	{
		UWidgetBlueprint* WBP = CastChecked<UWidgetBlueprint>(NewBlueprint(Dir / FString::Printf(TEXT("WBP_%sPanel"), *Core),
			UUserWidget::StaticClass(), UWidgetBlueprint::StaticClass(), UWidgetBlueprintGeneratedClass::StaticClass()));
		CheckNames({TEXT("SetBackground"), TEXT("SetBackgroundPadding"), TEXT("SetTag"), TEXT("SetBackgroundMaterial"), TEXT("SetBackgroundSolid")});

		UWidgetTree* T = WBP->WidgetTree;
		UBorder* Background = T->ConstructWidget<UBorder>(UBorder::StaticClass(), TEXT("Background"));
		Background->SetBrushColor(FLinearColor(0.f, 0.f, 0.f, 0.f));
		Background->SetPadding(FMargin(0.f));
		Background->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		Background->bIsVariable = true;
		T->RootWidget = Background;
		UOverlay* Layers = T->ConstructWidget<UOverlay>(UOverlay::StaticClass(), TEXT("Layers"));
		Layers->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		UBorderSlot* LayersSlot = CastChecked<UBorderSlot>(Background->AddChild(Layers));
		LayersSlot->SetPadding(FMargin(0.f));
		LayersSlot->SetHorizontalAlignment(HAlign_Fill);
		LayersSlot->SetVerticalAlignment(VAlign_Fill);
		UVerticalBox* VBox = T->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), TEXT("VBox"));
		UHorizontalBox* HBox = T->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("HBox"));
		for (UPanelWidget* Box : {static_cast<UPanelWidget*>(VBox), static_cast<UPanelWidget*>(HBox)})
		{
			Box->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
			Box->bIsVariable = true;
			UOverlaySlot* BoxSlot = CastChecked<UOverlaySlot>(Layers->AddChild(Box));
			BoxSlot->SetHorizontalAlignment(HAlign_Fill);
			BoxSlot->SetVerticalAlignment(VAlign_Fill);
		}
		WBP->OnVariableAdded(TEXT("Background"));
		WBP->OnVariableAdded(TEXT("Layers")); // every widget in the tree needs its GUID, variable or not
		WBP->OnVariableAdded(TEXT("VBox"));
		WBP->OnVariableAdded(TEXT("HBox"));

		// The functions need the compiled widget variables, so compile first.
		FFunc SetBg = AddSetBackground(WBP);
		FFunc SetPad = AddFunction(WBP, TEXT("SetBackgroundPadding"), {{TEXT("Padding"), RealT()}}, {});
		FFunc SetTag = AddTag(WBP);
		FMaterialFns Mat = AddBackgroundMaterial(WBP);
		if (!Compile(WBP)) return nullptr;
		FillBackground(WBP, SetBg, SetPad);
		FillTag(WBP, SetTag);
		FillBackgroundMaterial(WBP, Mat);
		if (!Compile(WBP) || !Save(WBP)) return nullptr;
		return WBP;
	}

	/**
	 * WBP_<Core>Button (story 15): SizeBox "Box" (story 2) -> Button "Btn" -> HorizontalBox "Content" (core story 24) ->
	 * [SizeBox "IconBox" (collapsed until SetIcon) -> Image "Icon"], Spacer "IconGap" (8 x 1, collapsed), TextBlock "Label"
	 * (white, drop shadow, size 18, centred). Lua makes an icon-only button by collapsing Label and IconGap and setting
	 * Box's width and height overrides to the icon's size, and shows IconGap for an icon with a label. Functions:
	 *   SetLabel(NewLabel: String)          Label.SetText(NewLabel)
	 *   SetEnabledState(Enabled: Bool)      Btn.SetIsEnabled(Enabled) (a disabled button never fires OnClicked)
	 *   SetColors(NR, NG, NB, NA, HR, HG, HB, HA, PR, PG, PB, PA, Padding: Float)
	 *                                       Btn.SetStyle: a solid brush per state (normal and disabled N, hovered H,
	 *                                       pressed P) and the same padding all round in both padding slots; story 2:
	 *                                       also Btn.SetBackgroundColor(white) and Box.SetMinDesiredHeight(0), so a
	 *                                       plain style after a game one looks plain again
	 *   SetMaterials(Normal, Hover: MaterialInterface, R, G, B, A, PadL, PadT, PadR, PadB, MinHeight: Float)   story 2
	 *                                       Btn.SetStyle(normal and disabled from Normal, hovered and pressed from
	 *                                       Hover, padding L/T/R/B), Btn.SetBackgroundColor((R, G, B, A)) (the tint),
	 *                                       Box.SetMinDesiredHeight(MinHeight)
	 *   SetLabelLook(Font: Object, Size, NR, NG, NB, NA, HR, HG, HB, HA, ShadowA: Float)   story 2
	 *                                       NormalTextColor/HoverTextColor = N/H, Label font (Font, Size), colour N,
	 *                                       shadow (0, 0, 0, ShadowA). Btn.OnHovered sets the label to HoverTextColor,
	 *                                       OnUnhovered to NormalTextColor (both white by default: no visible change)
	 *   SetTag(NewTag: String)              CoreTag = NewTag
	 *   <Core>_OnClicked()                  ClickCount += 1. The button's OnClicked calls it and nothing else; each
	 *                                       dependent's Lua post-hooks it by full path (bp-spike's NNSpike_OnClicked)
	 * Core story 24 (icons, dimmed):
	 *   SetIcon(Texture: Object, W, H: Float)   IconBox width/height overrides W/H, Icon's brush resource = Texture,
	 *                                       IconBox HitTestInvisible (shown)
	 *   ClearIcon()                         IconBox Collapsed, Icon's brush resource cleared
	 *   SetContentColors(NR, NG, NB, NA, HR, HG, HB, HA: Float)   NormalTextColor/HoverTextColor = N/H, Label and Icon
	 *                                       drawn in N now; Btn.OnHovered/OnUnhovered colour the Icon like the Label
	 *                                       (SetLabelLook colours the Icon too)
	 * Lua draws it disabled at the theme's opacity (SetRenderOpacity on the widget), its icon included.
	 */
	UWidgetBlueprint* BuildButton(const FString& Dir, const FString& Core)
	{
		UWidgetBlueprint* WBP = CastChecked<UWidgetBlueprint>(NewBlueprint(Dir / FString::Printf(TEXT("WBP_%sButton"), *Core),
			UUserWidget::StaticClass(), UWidgetBlueprint::StaticClass(), UWidgetBlueprintGeneratedClass::StaticClass()));
		const FString ClickFn = Core + TEXT("_OnClicked");
		CheckNames({TEXT("SetLabel"), TEXT("SetEnabledState"), TEXT("SetColors"), TEXT("SetTag"), *ClickFn,
			TEXT("SetMaterials"), TEXT("SetLabelLook"), TEXT("SetIcon"), TEXT("ClearIcon"), TEXT("SetContentColors")});

		UWidgetTree* T = WBP->WidgetTree;
		USizeBox* Box = T->ConstructWidget<USizeBox>(USizeBox::StaticClass(), TEXT("Box"));
		Box->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		Box->bIsVariable = true;
		T->RootWidget = Box;
		UButton* Btn = T->ConstructWidget<UButton>(UButton::StaticClass(), TEXT("Btn"));
		Btn->bIsVariable = true;
		USizeBoxSlot* BtnSlot = CastChecked<USizeBoxSlot>(Box->AddChild(Btn));
		BtnSlot->SetHorizontalAlignment(HAlign_Fill);
		BtnSlot->SetVerticalAlignment(VAlign_Fill);
		UTextBlock* Label = T->ConstructWidget<UTextBlock>(UTextBlock::StaticClass(), TEXT("Label"));
		Label->SetText(FText::GetEmpty());
		Label->SetColorAndOpacity(FSlateColor(FLinearColor::White));
		Label->SetShadowOffset(FVector2D(1.f, 1.f));
		Label->SetShadowColorAndOpacity(FLinearColor(0.f, 0.f, 0.f, 0.85f));
		FSlateFontInfo Font = Label->GetFont();
		Font.Size = 18;
		Label->SetFont(Font);
		Label->SetJustification(ETextJustify::Center);
		Label->SetVisibility(ESlateVisibility::HitTestInvisible);
		Label->bIsVariable = true;
		// Core story 24: the button's content is a row [icon box, gap, label], centred as the label alone was; with no
		// icon the icon box and the gap are collapsed (zero size), so a 0.7.0 button looks and measures the same.
		UHorizontalBox* Content = T->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("Content"));
		Content->SetVisibility(ESlateVisibility::HitTestInvisible);
		Content->bIsVariable = true;
		UButtonSlot* ContentSlot = CastChecked<UButtonSlot>(Btn->AddChild(Content));
		ContentSlot->SetPadding(FMargin(0.f));
		ContentSlot->SetHorizontalAlignment(HAlign_Center);
		ContentSlot->SetVerticalAlignment(VAlign_Center);
		USizeBox* IconBox = T->ConstructWidget<USizeBox>(USizeBox::StaticClass(), TEXT("IconBox"));
		IconBox->SetVisibility(ESlateVisibility::Collapsed);
		IconBox->SetWidthOverride(24.f);
		IconBox->SetHeightOverride(24.f);
		IconBox->bIsVariable = true;
		UImage* Icon = T->ConstructWidget<UImage>(UImage::StaticClass(), TEXT("Icon"));
		Icon->SetVisibility(ESlateVisibility::HitTestInvisible);
		Icon->bIsVariable = true;
		USizeBoxSlot* IconSlot = CastChecked<USizeBoxSlot>(IconBox->AddChild(Icon));
		IconSlot->SetHorizontalAlignment(HAlign_Fill);
		IconSlot->SetVerticalAlignment(VAlign_Fill);
		USpacer* IconGap = T->ConstructWidget<USpacer>(USpacer::StaticClass(), TEXT("IconGap"));
		IconGap->SetSize(FVector2D(8.f, 1.f));
		IconGap->SetVisibility(ESlateVisibility::Collapsed);
		IconGap->bIsVariable = true;
		for (UWidget* W : {static_cast<UWidget*>(IconBox), static_cast<UWidget*>(IconGap), static_cast<UWidget*>(Label)})
		{
			UHorizontalBoxSlot* S = CastChecked<UHorizontalBoxSlot>(Content->AddChild(W));
			S->SetPadding(FMargin(0.f));
			S->SetHorizontalAlignment(HAlign_Center);
			S->SetVerticalAlignment(VAlign_Center);
		}
		WBP->OnVariableAdded(TEXT("Box"));
		WBP->OnVariableAdded(TEXT("Btn"));
		WBP->OnVariableAdded(TEXT("Content"));
		WBP->OnVariableAdded(TEXT("IconBox"));
		WBP->OnVariableAdded(TEXT("Icon"));
		WBP->OnVariableAdded(TEXT("IconGap"));
		WBP->OnVariableAdded(TEXT("Label"));
		FBlueprintEditorUtils::AddMemberVariable(WBP, TEXT("ClickCount"), IntT(), TEXT("0"));
		FBlueprintEditorUtils::AddMemberVariable(WBP, TEXT("NormalTextColor"), LinearColorT(), WhiteColor);
		FBlueprintEditorUtils::AddMemberVariable(WBP, TEXT("HoverTextColor"), LinearColorT(), WhiteColor);

		// The functions need the compiled widget variables, so compile first.
		FFunc SetLabel = AddFunction(WBP, TEXT("SetLabel"), {{TEXT("NewLabel"), StrT()}}, {});
		FFunc SetEnabled = AddFunction(WBP, TEXT("SetEnabledState"), {{TEXT("Enabled"), BoolT()}}, {});
		FParams ColorsIn;
		for (const TCHAR* State : {TEXT("N"), TEXT("H"), TEXT("P")})
		{
			for (const TCHAR* Ch : {TEXT("R"), TEXT("G"), TEXT("B"), TEXT("A")})
			{
				ColorsIn.Add({FName(FString(State) + Ch), RealT()});
			}
		}
		ColorsIn.Add({TEXT("Padding"), RealT()});
		FFunc SetColors = AddFunction(WBP, TEXT("SetColors"), ColorsIn, {});
		FFunc SetTag = AddTag(WBP);
		FFunc OnClicked = AddFunction(WBP, FName(ClickFn), {}, {});
		FFunc SetMats = AddFunction(WBP, TEXT("SetMaterials"), {{TEXT("Normal"), ObjT(UMaterialInterface::StaticClass())},
			{TEXT("Hover"), ObjT(UMaterialInterface::StaticClass())}, {TEXT("R"), RealT()}, {TEXT("G"), RealT()}, {TEXT("B"), RealT()},
			{TEXT("A"), RealT()}, {TEXT("PadL"), RealT()}, {TEXT("PadT"), RealT()}, {TEXT("PadR"), RealT()}, {TEXT("PadB"), RealT()},
			{TEXT("MinHeight"), RealT()}}, {});
		FParams LookIn = {{TEXT("Font"), ObjT(UObject::StaticClass())}, {TEXT("Size"), RealT()}};
		for (const TCHAR* State : {TEXT("N"), TEXT("H")})
		{
			for (const TCHAR* Ch : {TEXT("R"), TEXT("G"), TEXT("B"), TEXT("A")})
			{
				LookIn.Add({FName(FString(State) + Ch), RealT()});
			}
		}
		LookIn.Add({TEXT("ShadowA"), RealT()});
		FFunc SetLook = AddFunction(WBP, TEXT("SetLabelLook"), LookIn, {});
		FFunc SetIcon = AddFunction(WBP, TEXT("SetIcon"), {{TEXT("Texture"), ObjT(UObject::StaticClass())}, {TEXT("W"), RealT()}, {TEXT("H"), RealT()}}, {});
		FFunc ClearIcon = AddFunction(WBP, TEXT("ClearIcon"), {}, {});
		FParams ContentIn;
		for (const TCHAR* State : {TEXT("N"), TEXT("H")})
		{
			for (const TCHAR* Ch : {TEXT("R"), TEXT("G"), TEXT("B"), TEXT("A")})
			{
				ContentIn.Add({FName(FString(State) + Ch), RealT()});
			}
		}
		FFunc SetContent = AddFunction(WBP, TEXT("SetContentColors"), ContentIn, {});
		if (!Compile(WBP)) return nullptr;
		FillTag(WBP, SetTag);
		{
			// SetIcon(Texture, W, H): IconBox overrides, Icon's brush resource, IconBox shown (hit-test invisible).
			FGraph G(WBP, SetIcon.G);
			UK2Node_VariableGet* GetBox = G.Get(TEXT("IconBox"));
			UK2Node_CallFunction* SetW = G.Call(USizeBox::StaticClass(), GET_FUNCTION_NAME_CHECKED(USizeBox, SetWidthOverride));
			G.Link(GetBox, TEXT("IconBox"), SetW, PN_Self);
			G.Link(SetIcon.Entry, TEXT("W"), SetW, TEXT("InWidthOverride"));
			UK2Node_CallFunction* SetH = G.Call(USizeBox::StaticClass(), GET_FUNCTION_NAME_CHECKED(USizeBox, SetHeightOverride));
			G.Link(GetBox, TEXT("IconBox"), SetH, PN_Self);
			G.Link(SetIcon.Entry, TEXT("H"), SetH, TEXT("InHeightOverride"));
			UK2Node_VariableGet* GetIcon = G.Get(TEXT("Icon"));
			UK2Node_CallFunction* SetRes = G.Call(UImage::StaticClass(), GET_FUNCTION_NAME_CHECKED(UImage, SetBrushResourceObject));
			G.Link(GetIcon, TEXT("Icon"), SetRes, PN_Self);
			G.Link(SetIcon.Entry, TEXT("Texture"), SetRes, TEXT("ResourceObject"));
			UK2Node_CallFunction* Show = G.Call(UWidget::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidget, SetVisibility));
			G.Link(GetBox, TEXT("IconBox"), Show, PN_Self);
			G.Default(Show, TEXT("InVisibility"), TEXT("HitTestInvisible"));
			G.Chain({SetIcon.Entry, SetW, SetH, SetRes, Show});
		}
		{
			// ClearIcon(): IconBox collapsed, Icon's brush resource cleared.
			FGraph G(WBP, ClearIcon.G);
			UK2Node_VariableGet* GetBox = G.Get(TEXT("IconBox"));
			UK2Node_CallFunction* Hide = G.Call(UWidget::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidget, SetVisibility));
			G.Link(GetBox, TEXT("IconBox"), Hide, PN_Self);
			G.Default(Hide, TEXT("InVisibility"), TEXT("Collapsed"));
			UK2Node_VariableGet* GetIcon = G.Get(TEXT("Icon"));
			UK2Node_CallFunction* SetRes = G.Call(UImage::StaticClass(), GET_FUNCTION_NAME_CHECKED(UImage, SetBrushResourceObject));
			G.Link(GetIcon, TEXT("Icon"), SetRes, PN_Self);
			G.Chain({ClearIcon.Entry, Hide, SetRes});
		}
		{
			// SetContentColors(N, H): the two colour variables, then the Label and the Icon in N.
			FGraph G(WBP, SetContent.G);
			UK2Node_CallFunction* N = ColorFrom(G, SetContent.Entry, TEXT("N"));
			UK2Node_CallFunction* H = ColorFrom(G, SetContent.Entry, TEXT("H"));
			UK2Node_VariableSet* SetN = G.Set(TEXT("NormalTextColor"));
			G.Link(N, PN_Ret, SetN, TEXT("NormalTextColor"));
			UK2Node_VariableSet* SetHv = G.Set(TEXT("HoverTextColor"));
			G.Link(H, PN_Ret, SetHv, TEXT("HoverTextColor"));
			UK2Node_VariableGet* GetLabel = G.Get(TEXT("Label"));
			UK2Node_CallFunction* SetC = G.Call(UTextBlock::StaticClass(), GET_FUNCTION_NAME_CHECKED(UTextBlock, SetColorAndOpacity));
			G.Link(GetLabel, TEXT("Label"), SetC, PN_Self);
			G.Link(SlateColorOf(G, G.Pin(N, PN_Ret)), G.Pin(SetC, TEXT("InColorAndOpacity")));
			UK2Node_VariableGet* GetIcon = G.Get(TEXT("Icon"));
			UK2Node_CallFunction* SetI = G.Call(UImage::StaticClass(), GET_FUNCTION_NAME_CHECKED(UImage, SetColorAndOpacity));
			G.Link(GetIcon, TEXT("Icon"), SetI, PN_Self);
			G.Link(N, PN_Ret, SetI, TEXT("InColorAndOpacity"));
			G.Chain({SetContent.Entry, SetN, SetHv, SetC, SetI});
		}
		{
			FGraph G(WBP, SetLabel.G);
			UK2Node_VariableGet* GetLabel = G.Get(TEXT("Label"));
			UK2Node_CallFunction* ToText = G.Call(UKismetTextLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetTextLibrary, Conv_StringToText));
			G.Link(SetLabel.Entry, TEXT("NewLabel"), ToText, TEXT("InString"));
			UK2Node_CallFunction* Set = G.Call(UTextBlock::StaticClass(), GET_FUNCTION_NAME_CHECKED(UTextBlock, SetText));
			G.Link(GetLabel, TEXT("Label"), Set, PN_Self);
			G.Link(ToText, PN_Ret, Set, TEXT("InText"));
			G.Chain({SetLabel.Entry, Set});
		}
		{
			FGraph G(WBP, SetEnabled.G);
			UK2Node_VariableGet* GetBtn = G.Get(TEXT("Btn"));
			UK2Node_CallFunction* Set = G.Call(UWidget::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidget, SetIsEnabled));
			G.Link(GetBtn, TEXT("Btn"), Set, PN_Self);
			G.Link(SetEnabled.Entry, TEXT("Enabled"), Set, TEXT("bInIsEnabled"));
			G.Chain({SetEnabled.Entry, Set});
		}
		{
			// SetColors: Btn.SetStyle(Make ButtonStyle(Normal/Disabled = brush N, Hovered = brush H, Pressed = brush P,
			// NormalPadding = PressedPadding = Margin(Padding))), each brush Make SlateBrush(TintColor = Make SlateColor(
			// SpecifiedColor = MakeColor(r, g, b, a))): a solid box of that colour (a brush with no image draws one).
			FGraph G(WBP, SetColors.G);
			auto Brush = [&](const TCHAR* State) -> UEdGraphPin*
			{
				UK2Node_CallFunction* Make = G.Call(UKismetMathLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetMathLibrary, MakeColor));
				for (const TCHAR* Ch : {TEXT("R"), TEXT("G"), TEXT("B"), TEXT("A")})
				{
					G.Link(SetColors.Entry, FName(FString(State) + Ch), Make, FName(Ch));
				}
				UK2Node_MakeStruct* Color = G.MakeStruct(FSlateColor::StaticStruct());
				G.Link(Make, PN_Ret, Color, FName(TEXT("SpecifiedColor")));
				UK2Node_MakeStruct* B = G.MakeStruct(FSlateBrush::StaticStruct());
				G.Link(G.OnlyOutput(Color), G.Pin(B, FName(TEXT("TintColor"))));
				return G.OnlyOutput(B);
			};
			UK2Node_MakeStruct* Style = G.MakeStruct(FButtonStyle::StaticStruct());
			UEdGraphPin* Normal = Brush(TEXT("N"));
			G.Link(Normal, G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, Normal)));
			G.Link(Normal, G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, Disabled)));
			G.Link(Brush(TEXT("H")), G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, Hovered)));
			G.Link(Brush(TEXT("P")), G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, Pressed)));
			UK2Node_MakeStruct* Margin = G.MakeStruct(FMargin::StaticStruct());
			for (const FName Side : {GET_MEMBER_NAME_CHECKED(FMargin, Left), GET_MEMBER_NAME_CHECKED(FMargin, Top),
			                         GET_MEMBER_NAME_CHECKED(FMargin, Right), GET_MEMBER_NAME_CHECKED(FMargin, Bottom)})
			{
				G.Link(SetColors.Entry, TEXT("Padding"), Margin, Side);
			}
			G.Link(G.OnlyOutput(Margin), G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, NormalPadding)));
			G.Link(G.OnlyOutput(Margin), G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, PressedPadding)));
			UK2Node_VariableGet* GetBtn = G.Get(TEXT("Btn"));
			UK2Node_CallFunction* Set = G.Call(UButton::StaticClass(), GET_FUNCTION_NAME_CHECKED(UButton, SetStyle));
			G.Link(GetBtn, TEXT("Btn"), Set, PN_Self);
			G.Link(G.OnlyOutput(Style), G.Pin(Set, TEXT("InStyle")));
			// Story 2: no tint and no minimum height, as before the game look existed.
			UK2Node_CallFunction* White = G.Call(UKismetMathLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetMathLibrary, MakeColor));
			for (const TCHAR* Ch : {TEXT("R"), TEXT("G"), TEXT("B"), TEXT("A")}) G.Default(White, FName(Ch), TEXT("1.0"));
			UK2Node_CallFunction* Tint = G.Call(UButton::StaticClass(), GET_FUNCTION_NAME_CHECKED(UButton, SetBackgroundColor));
			G.Link(GetBtn, TEXT("Btn"), Tint, PN_Self);
			G.Link(White, PN_Ret, Tint, TEXT("InBackgroundColor"));
			UK2Node_VariableGet* GetBox = G.Get(TEXT("Box"));
			UK2Node_CallFunction* Min = G.Call(USizeBox::StaticClass(), GET_FUNCTION_NAME_CHECKED(USizeBox, SetMinDesiredHeight));
			G.Link(GetBox, TEXT("Box"), Min, PN_Self);
			G.Default(Min, TEXT("InMinDesiredHeight"), TEXT("0.0"));
			G.Chain({SetColors.Entry, Set, Tint, Min});
		}
		{
			// SetMaterials: Btn.SetStyle(Make ButtonStyle(Normal/Disabled = brush of Normal, Hovered/Pressed = brush of
			// Hover, both paddings Margin(L, T, R, B))), Btn.SetBackgroundColor(tint), Box.SetMinDesiredHeight(MinHeight).
			FGraph G(WBP, SetMats.G);
			UEdGraphPin* NormalBrush = MaterialBrushOf(G, G.Pin(SetMats.Entry, TEXT("Normal")));
			UEdGraphPin* HoverBrush = MaterialBrushOf(G, G.Pin(SetMats.Entry, TEXT("Hover")));
			UK2Node_MakeStruct* Style = G.MakeStruct(FButtonStyle::StaticStruct());
			G.Link(NormalBrush, G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, Normal)));
			G.Link(NormalBrush, G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, Disabled)));
			G.Link(HoverBrush, G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, Hovered)));
			G.Link(HoverBrush, G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, Pressed)));
			UK2Node_MakeStruct* Margin = G.MakeStruct(FMargin::StaticStruct());
			G.Link(SetMats.Entry, TEXT("PadL"), Margin, GET_MEMBER_NAME_CHECKED(FMargin, Left));
			G.Link(SetMats.Entry, TEXT("PadT"), Margin, GET_MEMBER_NAME_CHECKED(FMargin, Top));
			G.Link(SetMats.Entry, TEXT("PadR"), Margin, GET_MEMBER_NAME_CHECKED(FMargin, Right));
			G.Link(SetMats.Entry, TEXT("PadB"), Margin, GET_MEMBER_NAME_CHECKED(FMargin, Bottom));
			G.Link(G.OnlyOutput(Margin), G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, NormalPadding)));
			G.Link(G.OnlyOutput(Margin), G.Pin(Style, GET_MEMBER_NAME_CHECKED(FButtonStyle, PressedPadding)));
			UK2Node_VariableGet* GetBtn = G.Get(TEXT("Btn"));
			UK2Node_CallFunction* Set = G.Call(UButton::StaticClass(), GET_FUNCTION_NAME_CHECKED(UButton, SetStyle));
			G.Link(GetBtn, TEXT("Btn"), Set, PN_Self);
			G.Link(G.OnlyOutput(Style), G.Pin(Set, TEXT("InStyle")));
			UK2Node_CallFunction* Make = ColorFrom(G, SetMats.Entry, TEXT(""));
			UK2Node_CallFunction* Tint = G.Call(UButton::StaticClass(), GET_FUNCTION_NAME_CHECKED(UButton, SetBackgroundColor));
			G.Link(GetBtn, TEXT("Btn"), Tint, PN_Self);
			G.Link(Make, PN_Ret, Tint, TEXT("InBackgroundColor"));
			UK2Node_VariableGet* GetBox = G.Get(TEXT("Box"));
			UK2Node_CallFunction* Min = G.Call(USizeBox::StaticClass(), GET_FUNCTION_NAME_CHECKED(USizeBox, SetMinDesiredHeight));
			G.Link(GetBox, TEXT("Box"), Min, PN_Self);
			G.Link(SetMats.Entry, TEXT("MinHeight"), Min, TEXT("InMinDesiredHeight"));
			G.Chain({SetMats.Entry, Set, Tint, Min});
		}
		{
			// SetLabelLook: the two colour variables, then the label's font, normal colour and shadow.
			FGraph G(WBP, SetLook.G);
			UK2Node_CallFunction* N = ColorFrom(G, SetLook.Entry, TEXT("N"));
			UK2Node_CallFunction* H = ColorFrom(G, SetLook.Entry, TEXT("H"));
			UK2Node_VariableSet* SetN = G.Set(TEXT("NormalTextColor"));
			G.Link(N, PN_Ret, SetN, TEXT("NormalTextColor"));
			UK2Node_VariableSet* SetH = G.Set(TEXT("HoverTextColor"));
			G.Link(H, PN_Ret, SetH, TEXT("HoverTextColor"));
			UK2Node_VariableGet* GetLabel = G.Get(TEXT("Label"));
			UEdGraphPin* Info = FontInfoOf(G, G.Pin(SetLook.Entry, TEXT("Font")), G.Pin(SetLook.Entry, TEXT("Size")));
			UK2Node_CallFunction* SetF = G.Call(UTextBlock::StaticClass(), GET_FUNCTION_NAME_CHECKED(UTextBlock, SetFont));
			G.Link(GetLabel, TEXT("Label"), SetF, PN_Self);
			G.Link(Info, G.Pin(SetF, TEXT("InFontInfo")));
			UK2Node_CallFunction* SetC = G.Call(UTextBlock::StaticClass(), GET_FUNCTION_NAME_CHECKED(UTextBlock, SetColorAndOpacity));
			G.Link(GetLabel, TEXT("Label"), SetC, PN_Self);
			G.Link(SlateColorOf(G, G.Pin(N, PN_Ret)), G.Pin(SetC, TEXT("InColorAndOpacity")));
			UK2Node_CallFunction* Shadow = ColorAlphaFrom(G, SetLook.Entry, TEXT("ShadowA"), TEXT("0.0"), TEXT("0.0"), TEXT("0.0"));
			UK2Node_CallFunction* SetS = G.Call(UTextBlock::StaticClass(), GET_FUNCTION_NAME_CHECKED(UTextBlock, SetShadowColorAndOpacity));
			G.Link(GetLabel, TEXT("Label"), SetS, PN_Self);
			G.Link(Shadow, PN_Ret, SetS, TEXT("InShadowColorAndOpacity"));
			// Core story 24: the icon takes the label's colour.
			UK2Node_VariableGet* GetIcon = G.Get(TEXT("Icon"));
			UK2Node_CallFunction* SetI = G.Call(UImage::StaticClass(), GET_FUNCTION_NAME_CHECKED(UImage, SetColorAndOpacity));
			G.Link(GetIcon, TEXT("Icon"), SetI, PN_Self);
			G.Link(N, PN_Ret, SetI, TEXT("InColorAndOpacity"));
			G.Chain({SetLook.Entry, SetN, SetH, SetF, SetC, SetS, SetI});
		}
		{
			// <Core>_OnClicked(): ClickCount = ClickCount + 1.
			FGraph G(WBP, OnClicked.G);
			UK2Node_VariableGet* GetCount = G.Get(TEXT("ClickCount"));
			UK2Node_CallFunction* Add = G.Call(UKismetMathLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetMathLibrary, Add_IntInt));
			G.Link(GetCount, TEXT("ClickCount"), Add, TEXT("A"));
			G.Default(Add, TEXT("B"), TEXT("1"));
			UK2Node_VariableSet* SetCount = G.Set(TEXT("ClickCount"));
			G.Link(Add, PN_Ret, SetCount, TEXT("ClickCount"));
			G.Chain({OnClicked.Entry, SetCount});
		}
		{
			// Event graph: Btn.OnClicked -> <Core>_OnClicked(), nothing else.
			UEdGraph* EG = FBlueprintEditorUtils::FindEventGraph(WBP);
			ClearGraph(WBP, EG);
			FGraph G(WBP, EG);
			FObjectProperty* BtnProp = FindFProperty<FObjectProperty>(WBP->SkeletonGeneratedClass, TEXT("Btn"));
			FMulticastDelegateProperty* Delegate = FindFProperty<FMulticastDelegateProperty>(UButton::StaticClass(), TEXT("OnClicked"));
			check(BtnProp && Delegate);
			FGraphNodeCreator<UK2Node_ComponentBoundEvent> C(*EG);
			UK2Node_ComponentBoundEvent* Bound = C.CreateNode(false);
			Bound->InitializeComponentBoundEventParams(BtnProp, Delegate);
			G.Place(Bound);
			C.Finalize();
			UK2Node_CallFunction* Call = G.CallSelf(FName(ClickFn));
			G.Chain({Bound, Call});
			// Story 2: Btn.OnHovered / OnUnhovered -> the label's colour from HoverTextColor / NormalTextColor.
			const TPair<const TCHAR*, const TCHAR*> Hovers[] = {{TEXT("OnHovered"), TEXT("HoverTextColor")}, {TEXT("OnUnhovered"), TEXT("NormalTextColor")}};
			for (const TPair<const TCHAR*, const TCHAR*>& E : Hovers)
			{
				FMulticastDelegateProperty* HoverDelegate = FindFProperty<FMulticastDelegateProperty>(UButton::StaticClass(), E.Key);
				check(HoverDelegate);
				FGraphNodeCreator<UK2Node_ComponentBoundEvent> HC(*EG);
				UK2Node_ComponentBoundEvent* HoverBound = HC.CreateNode(false);
				HoverBound->InitializeComponentBoundEventParams(BtnProp, HoverDelegate);
				G.Place(HoverBound);
				HC.Finalize();
				UK2Node_VariableGet* GetColor = G.Get(E.Value);
				UK2Node_VariableGet* GetLabel = G.Get(TEXT("Label"));
				UK2Node_CallFunction* SetC = G.Call(UTextBlock::StaticClass(), GET_FUNCTION_NAME_CHECKED(UTextBlock, SetColorAndOpacity));
				G.Link(GetLabel, TEXT("Label"), SetC, PN_Self);
				G.Link(SlateColorOf(G, G.Pin(GetColor, E.Value)), G.Pin(SetC, TEXT("InColorAndOpacity")));
				// Core story 24: the icon follows the label (dimmed: both colours are the disabled one, no change).
				UK2Node_VariableGet* GetIcon = G.Get(TEXT("Icon"));
				UK2Node_CallFunction* SetI = G.Call(UImage::StaticClass(), GET_FUNCTION_NAME_CHECKED(UImage, SetColorAndOpacity));
				G.Link(GetIcon, TEXT("Icon"), SetI, PN_Self);
				G.Link(GetColor, E.Value, SetI, TEXT("InColorAndOpacity"));
				G.Chain({HoverBound, SetC, SetI});
			}
		}

		if (!Compile(WBP) || !Save(WBP)) return nullptr;
		return WBP;
	}

	/**
	 * WBP_<Core>List (story 2, Mod Manager v1): SizeBox "Box" -> Border "Background" -> ScrollBox "Scroll" -> VerticalBox
	 * "VBox". Lua puts the list's children into VBox (in its order, rebuilt like a panel's); the ScrollBox is Visible so
	 * the mouse wheel reaches it, every other container self-hit-test-invisible. Functions:
	 *   SetBackground(R, G, B, A), SetBackgroundPadding(Padding)                as on the text widget
	 *   SetBackgroundMaterial(Material, R, G, B, A, Padding), SetBackgroundSolid() as on the text widget
	 *   SetTag(NewTag: String)                                                  CoreTag = NewTag
	 *   SetListSize(W, H: Float)                                                Box width and height overrides
	 */
	UWidgetBlueprint* BuildList(const FString& Dir, const FString& Core)
	{
		UWidgetBlueprint* WBP = CastChecked<UWidgetBlueprint>(NewBlueprint(Dir / FString::Printf(TEXT("WBP_%sList"), *Core),
			UUserWidget::StaticClass(), UWidgetBlueprint::StaticClass(), UWidgetBlueprintGeneratedClass::StaticClass()));
		CheckNames({TEXT("SetBackground"), TEXT("SetBackgroundPadding"), TEXT("SetBackgroundMaterial"), TEXT("SetBackgroundSolid"),
			TEXT("SetTag"), TEXT("SetListSize")});

		UWidgetTree* T = WBP->WidgetTree;
		USizeBox* Box = T->ConstructWidget<USizeBox>(USizeBox::StaticClass(), TEXT("Box"));
		Box->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		Box->bIsVariable = true;
		T->RootWidget = Box;
		UBorder* Background = RootBackground(T);
		USizeBoxSlot* BgSlot = CastChecked<USizeBoxSlot>(Box->AddChild(Background));
		BgSlot->SetHorizontalAlignment(HAlign_Fill);
		BgSlot->SetVerticalAlignment(VAlign_Fill);
		UScrollBox* Scroll = T->ConstructWidget<UScrollBox>(UScrollBox::StaticClass(), TEXT("Scroll"));
		Scroll->SetVisibility(ESlateVisibility::Visible);
		Scroll->SetOrientation(Orient_Vertical);
		Scroll->bIsVariable = true;
		UBorderSlot* ScrollSlot = CastChecked<UBorderSlot>(Background->AddChild(Scroll));
		ScrollSlot->SetPadding(FMargin(0.f));
		ScrollSlot->SetHorizontalAlignment(HAlign_Fill);
		ScrollSlot->SetVerticalAlignment(VAlign_Fill);
		UVerticalBox* VBox = T->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), TEXT("VBox"));
		VBox->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		VBox->bIsVariable = true;
		Scroll->AddChild(VBox);
		for (const TCHAR* W : {TEXT("Box"), TEXT("Background"), TEXT("Scroll"), TEXT("VBox")}) WBP->OnVariableAdded(W);

		FFunc SetBg = AddSetBackground(WBP);
		FFunc SetPad = AddFunction(WBP, TEXT("SetBackgroundPadding"), {{TEXT("Padding"), RealT()}}, {});
		FFunc SetTag = AddTag(WBP);
		FMaterialFns Mat = AddBackgroundMaterial(WBP);
		FFunc SetSize = AddFunction(WBP, TEXT("SetListSize"), {{TEXT("W"), RealT()}, {TEXT("H"), RealT()}}, {});
		if (!Compile(WBP)) return nullptr;
		FillBackground(WBP, SetBg, SetPad);
		FillTag(WBP, SetTag);
		FillBackgroundMaterial(WBP, Mat);
		{
			FGraph G(WBP, SetSize.G);
			UK2Node_VariableGet* GetBox = G.Get(TEXT("Box"));
			UK2Node_CallFunction* SetW = G.Call(USizeBox::StaticClass(), GET_FUNCTION_NAME_CHECKED(USizeBox, SetWidthOverride));
			G.Link(GetBox, TEXT("Box"), SetW, PN_Self);
			G.Link(SetSize.Entry, TEXT("W"), SetW, TEXT("InWidthOverride"));
			UK2Node_CallFunction* SetH = G.Call(USizeBox::StaticClass(), GET_FUNCTION_NAME_CHECKED(USizeBox, SetHeightOverride));
			G.Link(GetBox, TEXT("Box"), SetH, PN_Self);
			G.Link(SetSize.Entry, TEXT("H"), SetH, TEXT("InHeightOverride"));
			G.Chain({SetSize.Entry, SetW, SetH});
		}
		if (!Compile(WBP) || !Save(WBP)) return nullptr;
		return WBP;
	}

	/**
	 * WBP_<Core>Row (story 2): Border "Background" -> HorizontalBox "HBox". Lua puts the row's children into HBox (Fill
	 * slots with a weight line up as columns, Auto otherwise). Both self-hit-test-invisible. Functions:
	 *   SetBackground(R, G, B, A), SetBackgroundPadding(Padding)                as on the text widget
	 *   SetBackgroundMaterial(Material, R, G, B, A, Padding), SetBackgroundSolid() as on the text widget
	 *   SetTag(NewTag: String)                                                  CoreTag = NewTag
	 */
	UWidgetBlueprint* BuildRow(const FString& Dir, const FString& Core)
	{
		UWidgetBlueprint* WBP = CastChecked<UWidgetBlueprint>(NewBlueprint(Dir / FString::Printf(TEXT("WBP_%sRow"), *Core),
			UUserWidget::StaticClass(), UWidgetBlueprint::StaticClass(), UWidgetBlueprintGeneratedClass::StaticClass()));
		CheckNames({TEXT("SetBackground"), TEXT("SetBackgroundPadding"), TEXT("SetBackgroundMaterial"), TEXT("SetBackgroundSolid"), TEXT("SetTag")});

		UWidgetTree* T = WBP->WidgetTree;
		UBorder* Background = RootBackground(T);
		T->RootWidget = Background;
		UHorizontalBox* HBox = T->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("HBox"));
		HBox->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		HBox->bIsVariable = true;
		UBorderSlot* BoxSlot = CastChecked<UBorderSlot>(Background->AddChild(HBox));
		BoxSlot->SetPadding(FMargin(0.f));
		BoxSlot->SetHorizontalAlignment(HAlign_Fill);
		BoxSlot->SetVerticalAlignment(VAlign_Fill);
		WBP->OnVariableAdded(TEXT("Background"));
		WBP->OnVariableAdded(TEXT("HBox"));

		FFunc SetBg = AddSetBackground(WBP);
		FFunc SetPad = AddFunction(WBP, TEXT("SetBackgroundPadding"), {{TEXT("Padding"), RealT()}}, {});
		FFunc SetTag = AddTag(WBP);
		FMaterialFns Mat = AddBackgroundMaterial(WBP);
		if (!Compile(WBP)) return nullptr;
		FillBackground(WBP, SetBg, SetPad);
		FillTag(WBP, SetTag);
		FillBackgroundMaterial(WBP, Mat);
		if (!Compile(WBP) || !Save(WBP)) return nullptr;
		return WBP;
	}

	/**
	 * Core story 24: core's icons. Each <file>.png in -IconDir (build.ps1 passes art/icons) becomes the texture
	 * /Game/Mods/<Core>/Icons/T_<Key in CamelCase>: UserInterface2D (TC_EditorIcon, uncompressed RGBA), no mips, the UI
	 * texture group, never streamed, sRGB. The PNGs must be 128x128 (white on transparent; Lua tints them). A missing or
	 * unreadable PNG fails the build: the pak would otherwise ship without an icon the Lua names.
	 */
	bool BuildIcons(const FString& Dir, const FString& IconDir)
	{
		struct FIcon { const TCHAR* File; const TCHAR* Asset; };
		const FIcon Icons[] = {
			{TEXT("gear"), TEXT("T_Gear")}, {TEXT("checkbox-on"), TEXT("T_CheckboxOn")}, {TEXT("checkbox-off"), TEXT("T_CheckboxOff")},
			{TEXT("lock"), TEXT("T_Lock")}, {TEXT("warning"), TEXT("T_Warning")}, {TEXT("restart"), TEXT("T_Restart")},
		};
		if (IconDir.IsEmpty())
		{
			UE_LOG(LogCoreGen, Error, TEXT("ICONS: pass -IconDir=<the art/icons folder> (build.ps1 does)"));
			return false;
		}
		for (const FIcon& I : Icons)
		{
			const FString File = FPaths::Combine(IconDir, FString(I.File) + TEXT(".png"));
			if (!FPaths::FileExists(File))
			{
				UE_LOG(LogCoreGen, Error, TEXT("ICONS: %s is missing"), *File);
				return false;
			}
			FImage Image;
			if (!FImageUtils::LoadImage(*File, Image))
			{
				UE_LOG(LogCoreGen, Error, TEXT("ICONS: %s could not be read as an image"), *File);
				return false;
			}
			if (Image.SizeX != 128 || Image.SizeY != 128)
			{
				UE_LOG(LogCoreGen, Error, TEXT("ICONS: %s is %dx%d; core's icons are 128x128"), *File, Image.SizeX, Image.SizeY);
				return false;
			}
			Image.ChangeFormat(ERawImageFormat::BGRA8, EGammaSpace::sRGB);
			const FString LongName = Dir / TEXT("Icons") / I.Asset;
			UPackage* Pkg = CreatePackage(*LongName);
			Pkg->FullyLoad();
			UTexture2D* Tex = NewObject<UTexture2D>(Pkg, FName(I.Asset), RF_Public | RF_Standalone);
			Tex->PreEditChange(nullptr);
			Tex->Source.Init(Image);
			Tex->SRGB = true;
			Tex->MipGenSettings = TMGS_NoMipmaps;
			Tex->CompressionSettings = TC_EditorIcon; // UserInterface2D (RGBA), uncompressed
			Tex->LODGroup = TEXTUREGROUP_UI;
			Tex->NeverStream = true;
			Tex->PostEditChange();
			if (!Save(Tex)) return false;
			UE_LOG(LogCoreGen, Display, TEXT("ICON %s <- %s (%dx%d)"), *LongName, *File, Image.SizeX, Image.SizeY);
		}
		return true;
	}

	/**
	 * WBP_<Core>Image (core story 24): SizeBox "Box" (32 x 32, self-hit-test-invisible) -> Image "Img" (fills the box,
	 * hit-test invisible, tint alpha 0: nothing drawn until Lua sets a texture and a tint). Lua sets Img visible only
	 * while the image has a tooltip. Functions:
	 *   SetImageTexture(Texture: Object)   Img's brush resource = Texture (one of core's icons, or an allow-listed game
	 *                                      texture loaded by path at runtime; nothing of the game's is cooked in)
	 *   ClearImageTexture()                Img's brush resource cleared
	 *   SetImageSize(W, H: Float)          Box width and height overrides
	 *   SetImageTint(R, G, B, A: Float)    Img.SetColorAndOpacity((R, G, B, A))
	 *   SetTag(NewTag: String)             CoreTag = NewTag
	 */
	UWidgetBlueprint* BuildImage(const FString& Dir, const FString& Core)
	{
		UWidgetBlueprint* WBP = CastChecked<UWidgetBlueprint>(NewBlueprint(Dir / FString::Printf(TEXT("WBP_%sImage"), *Core),
			UUserWidget::StaticClass(), UWidgetBlueprint::StaticClass(), UWidgetBlueprintGeneratedClass::StaticClass()));
		CheckNames({TEXT("SetImageTexture"), TEXT("ClearImageTexture"), TEXT("SetImageSize"), TEXT("SetImageTint"), TEXT("SetTag")});

		UWidgetTree* T = WBP->WidgetTree;
		USizeBox* Box = T->ConstructWidget<USizeBox>(USizeBox::StaticClass(), TEXT("Box"));
		Box->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		Box->SetWidthOverride(32.f);
		Box->SetHeightOverride(32.f);
		Box->bIsVariable = true;
		T->RootWidget = Box;
		UImage* Img = T->ConstructWidget<UImage>(UImage::StaticClass(), TEXT("Img"));
		Img->SetVisibility(ESlateVisibility::HitTestInvisible);
		Img->SetColorAndOpacity(FLinearColor(1.f, 1.f, 1.f, 0.f));
		Img->bIsVariable = true;
		USizeBoxSlot* ImgSlot = CastChecked<USizeBoxSlot>(Box->AddChild(Img));
		ImgSlot->SetHorizontalAlignment(HAlign_Fill);
		ImgSlot->SetVerticalAlignment(VAlign_Fill);
		WBP->OnVariableAdded(TEXT("Box"));
		WBP->OnVariableAdded(TEXT("Img"));

		FFunc SetTex = AddFunction(WBP, TEXT("SetImageTexture"), {{TEXT("Texture"), ObjT(UObject::StaticClass())}}, {});
		FFunc ClearTex = AddFunction(WBP, TEXT("ClearImageTexture"), {}, {});
		FFunc SetSize = AddFunction(WBP, TEXT("SetImageSize"), {{TEXT("W"), RealT()}, {TEXT("H"), RealT()}}, {});
		FFunc SetTint = AddFunction(WBP, TEXT("SetImageTint"), {{TEXT("R"), RealT()}, {TEXT("G"), RealT()}, {TEXT("B"), RealT()}, {TEXT("A"), RealT()}}, {});
		FFunc SetTag = AddTag(WBP);
		if (!Compile(WBP)) return nullptr;
		FillTag(WBP, SetTag);
		{
			FGraph G(WBP, SetTex.G);
			UK2Node_VariableGet* GetImg = G.Get(TEXT("Img"));
			UK2Node_CallFunction* Set = G.Call(UImage::StaticClass(), GET_FUNCTION_NAME_CHECKED(UImage, SetBrushResourceObject));
			G.Link(GetImg, TEXT("Img"), Set, PN_Self);
			G.Link(SetTex.Entry, TEXT("Texture"), Set, TEXT("ResourceObject"));
			G.Chain({SetTex.Entry, Set});
		}
		{
			FGraph G(WBP, ClearTex.G);
			UK2Node_VariableGet* GetImg = G.Get(TEXT("Img"));
			UK2Node_CallFunction* Set = G.Call(UImage::StaticClass(), GET_FUNCTION_NAME_CHECKED(UImage, SetBrushResourceObject));
			G.Link(GetImg, TEXT("Img"), Set, PN_Self);
			G.Chain({ClearTex.Entry, Set});
		}
		{
			FGraph G(WBP, SetSize.G);
			UK2Node_VariableGet* GetBox = G.Get(TEXT("Box"));
			UK2Node_CallFunction* SetW = G.Call(USizeBox::StaticClass(), GET_FUNCTION_NAME_CHECKED(USizeBox, SetWidthOverride));
			G.Link(GetBox, TEXT("Box"), SetW, PN_Self);
			G.Link(SetSize.Entry, TEXT("W"), SetW, TEXT("InWidthOverride"));
			UK2Node_CallFunction* SetH = G.Call(USizeBox::StaticClass(), GET_FUNCTION_NAME_CHECKED(USizeBox, SetHeightOverride));
			G.Link(GetBox, TEXT("Box"), SetH, PN_Self);
			G.Link(SetSize.Entry, TEXT("H"), SetH, TEXT("InHeightOverride"));
			G.Chain({SetSize.Entry, SetW, SetH});
		}
		{
			FGraph G(WBP, SetTint.G);
			UK2Node_VariableGet* GetImg = G.Get(TEXT("Img"));
			UK2Node_CallFunction* Make = ColorFrom(G, SetTint.Entry, TEXT(""));
			UK2Node_CallFunction* Set = G.Call(UImage::StaticClass(), GET_FUNCTION_NAME_CHECKED(UImage, SetColorAndOpacity));
			G.Link(GetImg, TEXT("Img"), Set, PN_Self);
			G.Link(Make, PN_Ret, Set, TEXT("InColorAndOpacity"));
			G.Chain({SetTint.Entry, Set});
		}
		if (!Compile(WBP) || !Save(WBP)) return nullptr;
		return WBP;
	}

	/**
	 * WBP_<Core>Screen (story 2, the window stack): Overlay "Root" -> [Border "Backdrop" (Visible: hit-testable, so it
	 * blocks everything below; solid, colour (0, 0, 0, 0.85)), CanvasPanel "Canvas" (self-hit-test-invisible; the
	 * window's elements go here)]. Lua adds it to the viewport above the menu. The class default is focusable, so the
	 * top window can hold keyboard focus. Functions:
	 *   SetBackdrop(R, G, B, A: Float)      Backdrop.SetBrushColor((R, G, B, A))
	 *   SetTag(NewTag: String)              CoreTag = NewTag
	 */
	UWidgetBlueprint* BuildScreen(const FString& Dir, const FString& Core)
	{
		UWidgetBlueprint* WBP = CastChecked<UWidgetBlueprint>(NewBlueprint(Dir / FString::Printf(TEXT("WBP_%sScreen"), *Core),
			UUserWidget::StaticClass(), UWidgetBlueprint::StaticClass(), UWidgetBlueprintGeneratedClass::StaticClass()));
		CheckNames({TEXT("SetBackdrop"), TEXT("SetTag")});

		UWidgetTree* T = WBP->WidgetTree;
		UOverlay* Root = T->ConstructWidget<UOverlay>(UOverlay::StaticClass(), TEXT("Root"));
		Root->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		Root->bIsVariable = true;
		T->RootWidget = Root;
		UBorder* Backdrop = T->ConstructWidget<UBorder>(UBorder::StaticClass(), TEXT("Backdrop"));
		Backdrop->SetBrushColor(FLinearColor(0.f, 0.f, 0.f, 0.85f));
		Backdrop->SetPadding(FMargin(0.f));
		Backdrop->SetVisibility(ESlateVisibility::Visible);
		Backdrop->bIsVariable = true;
		UOverlaySlot* BackSlot = CastChecked<UOverlaySlot>(Root->AddChild(Backdrop));
		BackSlot->SetHorizontalAlignment(HAlign_Fill);
		BackSlot->SetVerticalAlignment(VAlign_Fill);
		UCanvasPanel* Canvas = T->ConstructWidget<UCanvasPanel>(UCanvasPanel::StaticClass(), TEXT("Canvas"));
		Canvas->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
		Canvas->bIsVariable = true;
		UOverlaySlot* CanvasSlot = CastChecked<UOverlaySlot>(Root->AddChild(Canvas));
		CanvasSlot->SetHorizontalAlignment(HAlign_Fill);
		CanvasSlot->SetVerticalAlignment(VAlign_Fill);
		WBP->OnVariableAdded(TEXT("Root"));
		WBP->OnVariableAdded(TEXT("Backdrop"));
		WBP->OnVariableAdded(TEXT("Canvas"));

		FFunc SetBackdrop = AddFunction(WBP, TEXT("SetBackdrop"), {{TEXT("R"), RealT()}, {TEXT("G"), RealT()}, {TEXT("B"), RealT()}, {TEXT("A"), RealT()}}, {});
		FFunc SetTag = AddTag(WBP);
		if (!Compile(WBP)) return nullptr;
		FillTag(WBP, SetTag);
		{
			FGraph G(WBP, SetBackdrop.G);
			UK2Node_VariableGet* GetBd = G.Get(TEXT("Backdrop"));
			UK2Node_CallFunction* Make = ColorFrom(G, SetBackdrop.Entry, TEXT(""));
			UK2Node_CallFunction* Set = G.Call(UBorder::StaticClass(), GET_FUNCTION_NAME_CHECKED(UBorder, SetBrushColor));
			G.Link(GetBd, TEXT("Backdrop"), Set, PN_Self);
			G.Link(Make, PN_Ret, Set, TEXT("InBrushColor"));
			G.Chain({SetBackdrop.Entry, Set});
		}
		if (!Compile(WBP)) return nullptr;
		UUserWidget* CDO = CastChecked<UUserWidget>(WBP->GeneratedClass->GetDefaultObject());
		CDO->SetIsFocusable(true);
		CDO->MarkPackageDirty();
		UE_LOG(LogCoreGen, Display, TEXT("SCREEN %s class default focusable=%s"), *WBP->GetPathName(), CDO->IsFocusable() ? TEXT("true") : TEXT("false"));
		if (!Save(WBP)) return nullptr;
		return WBP;
	}

	/** <Core>_Call(Request) -> ReturnValue: "bp-default:" + Request. Core's Lua RegisterHooks it and replaces the result. */
	void AddChannel(UBlueprint* BP, const FString& Core)
	{
		FFunc F = AddFunction(BP, FName(Core + TEXT("_Call")), {{TEXT("Request"), StrT()}}, {{PN_Ret, StrT()}});
		FGraph G(BP, F.G);
		UK2Node_CallFunction* Cat = G.Call(UKismetStringLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetStringLibrary, Concat_StrStr));
		G.Default(Cat, TEXT("A"), TEXT("bp-default:"));
		G.Link(F.Entry, TEXT("Request"), Cat, TEXT("B"));
		G.Link(Cat, PN_Ret, F.Result, PN_Ret);
		G.Chain({F.Entry, F.Result});
	}

	/**
	 * Internal geometry functions (not public API): screen rectangles of any widget, in Slate absolute coordinates
	 * (desktop pixels), and absolute -> a widget's local space. Read from the widget's cached geometry, so a widget that
	 * has not been laid out yet reports zeros.
	 *   <Core>_AbsTopLeft(Widget)          = LocalToAbsolute(geo, (0,0))
	 *   <Core>_AbsBottomRight(Widget)      = LocalToAbsolute(geo, LocalSize(geo))
	 *   <Core>_AbsToLocal(Widget, Absolute) = AbsoluteToLocal(geo, Absolute)
	 *   <Core>_RectIn(Canvas, Widget, Frac) = AbsoluteToLocal(Canvas geo, LocalToAbsolute(Widget geo, LocalSize(Widget geo) * Frac))
	 * _RectIn (story 19, journal regions) gives a point of Widget's rectangle in Canvas's local units (canvas units):
	 * Frac (0,0) is its top-left, (1,1) its bottom-right. The measured journal regions sit inside box panels, so only
	 * geometry knows them, and FGeometry isn't usable from Lua; one Vector2D return is the shape proven from Lua.
	 */
	void AddGeometry(UBlueprint* BP, const FString& Core)
	{
		const FParams WidgetIn = {{TEXT("Widget"), ObjT(UWidget::StaticClass())}};
		{
			FFunc F = AddFunction(BP, FName(Core + TEXT("_AbsTopLeft")), WidgetIn, {{PN_Ret, Vec2T()}});
			FGraph G(BP, F.G);
			UK2Node_CallFunction* Geo = G.Call(UWidget::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidget, GetCachedGeometry));
			G.Link(F.Entry, TEXT("Widget"), Geo, PN_Self);
			UK2Node_CallFunction* Abs = G.Call(USlateBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(USlateBlueprintLibrary, LocalToAbsolute));
			G.Link(Geo, PN_Ret, Abs, TEXT("Geometry"));
			G.Default(Abs, TEXT("LocalCoordinate"), TEXT("(X=0.000000,Y=0.000000)"));
			G.Link(Abs, PN_Ret, F.Result, PN_Ret);
			G.Chain({F.Entry, Geo, Abs, F.Result});
		}
		{
			FFunc F = AddFunction(BP, FName(Core + TEXT("_AbsBottomRight")), WidgetIn, {{PN_Ret, Vec2T()}});
			FGraph G(BP, F.G);
			UK2Node_CallFunction* Geo = G.Call(UWidget::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidget, GetCachedGeometry));
			G.Link(F.Entry, TEXT("Widget"), Geo, PN_Self);
			UK2Node_CallFunction* Size = G.Call(USlateBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(USlateBlueprintLibrary, GetLocalSize));
			G.Link(Geo, PN_Ret, Size, TEXT("Geometry"));
			UK2Node_CallFunction* Abs = G.Call(USlateBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(USlateBlueprintLibrary, LocalToAbsolute));
			G.Link(Geo, PN_Ret, Abs, TEXT("Geometry"));
			G.Link(Size, PN_Ret, Abs, TEXT("LocalCoordinate"));
			G.Link(Abs, PN_Ret, F.Result, PN_Ret);
			G.Chain({F.Entry, Geo, Size, Abs, F.Result});
		}
		{
			FParams In = WidgetIn;
			In.Add({TEXT("Absolute"), Vec2T()});
			FFunc F = AddFunction(BP, FName(Core + TEXT("_AbsToLocal")), In, {{PN_Ret, Vec2T()}});
			FGraph G(BP, F.G);
			UK2Node_CallFunction* Geo = G.Call(UWidget::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidget, GetCachedGeometry));
			G.Link(F.Entry, TEXT("Widget"), Geo, PN_Self);
			UK2Node_CallFunction* Local = G.Call(USlateBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(USlateBlueprintLibrary, AbsoluteToLocal));
			G.Link(Geo, PN_Ret, Local, TEXT("Geometry"));
			G.Link(F.Entry, TEXT("Absolute"), Local, TEXT("AbsoluteCoordinate"));
			G.Link(Local, PN_Ret, F.Result, PN_Ret);
			G.Chain({F.Entry, Geo, Local, F.Result});
		}
		{
			const FParams In = {{TEXT("Canvas"), ObjT(UWidget::StaticClass())}, {TEXT("Widget"), ObjT(UWidget::StaticClass())}, {TEXT("Frac"), Vec2T()}};
			FFunc F = AddFunction(BP, FName(Core + TEXT("_RectIn")), In, {{PN_Ret, Vec2T()}});
			FGraph G(BP, F.G);
			UK2Node_CallFunction* Geo = G.Call(UWidget::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidget, GetCachedGeometry));
			G.Link(F.Entry, TEXT("Widget"), Geo, PN_Self);
			UK2Node_CallFunction* CanvasGeo = G.Call(UWidget::StaticClass(), GET_FUNCTION_NAME_CHECKED(UWidget, GetCachedGeometry));
			G.Link(F.Entry, TEXT("Canvas"), CanvasGeo, PN_Self);
			UK2Node_CallFunction* Size = G.Call(USlateBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(USlateBlueprintLibrary, GetLocalSize));
			G.Link(Geo, PN_Ret, Size, TEXT("Geometry"));
			UK2Node_CallFunction* Mul = G.Call(UKismetMathLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(UKismetMathLibrary, Multiply_Vector2DVector2D));
			G.Link(Size, PN_Ret, Mul, TEXT("A"));
			G.Link(F.Entry, TEXT("Frac"), Mul, TEXT("B"));
			UK2Node_CallFunction* Abs = G.Call(USlateBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(USlateBlueprintLibrary, LocalToAbsolute));
			G.Link(Geo, PN_Ret, Abs, TEXT("Geometry"));
			G.Link(Mul, PN_Ret, Abs, TEXT("LocalCoordinate"));
			UK2Node_CallFunction* Local = G.Call(USlateBlueprintLibrary::StaticClass(), GET_FUNCTION_NAME_CHECKED(USlateBlueprintLibrary, AbsoluteToLocal));
			G.Link(CanvasGeo, PN_Ret, Local, TEXT("Geometry"));
			G.Link(Abs, PN_Ret, Local, TEXT("AbsoluteCoordinate"));
			G.Link(Local, PN_Ret, F.Result, PN_Ret);
			G.Chain({F.Entry, Geo, CanvasGeo, Size, Mul, Abs, Local, F.Result});
		}
	}

	/** /Game/Mods/<Core>/ModActor: the channel and the geometry functions. No events: core needs no BeginPlay logic. */
	UBlueprint* BuildActor(const FString& Dir, const FString& Core)
	{
		UBlueprint* BP = NewBlueprint(Dir / TEXT("ModActor"), AActor::StaticClass(), UBlueprint::StaticClass(), UBlueprintGeneratedClass::StaticClass());
		AddChannel(BP, Core);
		AddGeometry(BP, Core);
		ClearGraph(BP, FBlueprintEditorUtils::FindEventGraph(BP));
		if (!Compile(BP) || !Save(BP)) return nullptr;
		return BP;
	}

	// ---------------------------------------------------------------- the map markers (map service story 4)
	//
	// Public API under story 18's add-only rule: the class names, the settings (names, types) and the component layout
	// below never change once released. Cooked levels are unversioned and store a placed marker's properties by their
	// position in the class's property list, so an author's level cooked against these classes must load against
	// exactly the same layout (docs/custom-maps.md, stage 2). New settings or Item values are only ever appended.

	/** The preview slots every kind carries, in this order after DefaultSceneRoot. Never reorder, rename or resize. */
	constexpr int32 NumStaticSlots = 8;
	constexpr int32 NumSkeletalSlots = 2;
	const TCHAR* BoxMeshPath = TEXT("/Engine/BasicShapes/Cube.Cube");
	const TCHAR* BoxMaterialPath = TEXT("/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial");

	/** The twelve kinds, in build order: /Game/Mods/<Core>/Map/BP_Marker_<Kind>. The golden layout lists them in this order. */
	const TCHAR* const MarkerKinds[] = { TEXT("Start"), TEXT("Item"), TEXT("Intel"), TEXT("Computer"), TEXT("Generator"), TEXT("Lever"),
		TEXT("EnemySpawner"), TEXT("EnemyWaypoint"), TEXT("Landing"), TEXT("Map"), TEXT("Location"), TEXT("Sky") };

	/** E_MarkerItem's values, in order (the byte value is the index). Only ever appended; the map service maps each to the game's item class. */
	const TCHAR* const MarkerItems[] = { TEXT("Painkillers"), TEXT("Flashlight") };

	FEdGraphPinType ArrayOf(FEdGraphPinType T)
	{
		T.ContainerType = EPinContainerType::Array;
		return T;
	}

	/** /Game/Mods/<Core>/Map/E_MarkerItem: the Item marker's dropdown. */
	UUserDefinedEnum* BuildItemEnum(const FString& MapDir)
	{
		const FString LongName = MapDir / TEXT("E_MarkerItem");
		UPackage* Pkg = CreatePackage(*LongName);
		Pkg->FullyLoad();
		UUserDefinedEnum* Enum = CastChecked<UUserDefinedEnum>(FEnumEditorUtils::CreateUserDefinedEnum(Pkg, FName(FPackageName::GetShortName(LongName)), RF_Public | RF_Standalone | RF_Transactional));
		for (int32 I = 0; I < UE_ARRAY_COUNT(MarkerItems); ++I)
		{
			FEnumEditorUtils::AddNewEnumeratorForUserDefinedEnum(Enum);
			if (!FEnumEditorUtils::SetEnumeratorDisplayName(Enum, I, FText::FromString(MarkerItems[I])))
			{
				UE_LOG(LogCoreGen, Error, TEXT("E_MarkerItem: could not name value %d %s"), I, MarkerItems[I]);
				return nullptr;
			}
		}
		// The enum's own count entry (_MAX) follows the values; anything else means a value was added twice or lost.
		if (Enum->NumEnums() != UE_ARRAY_COUNT(MarkerItems) + 1)
		{
			UE_LOG(LogCoreGen, Error, TEXT("E_MarkerItem has %d entries, want %d values and _MAX"), Enum->NumEnums(), int32(UE_ARRAY_COUNT(MarkerItems)));
			return nullptr;
		}
		FString Values;
		for (int32 I = 0; I < UE_ARRAY_COUNT(MarkerItems); ++I)
		{
			// Frozen (story 4): the editor's own internal names NewEnumerator<N>, value N. Uncooked levels store the
			// value by its internal name, cooked ones by its number; both must stay.
			const FString Internal = Enum->GetNameStringByIndex(I);
			if (Internal != FString::Printf(TEXT("NewEnumerator%d"), I) || Enum->GetValueByIndex(I) != I)
			{
				UE_LOG(LogCoreGen, Error, TEXT("E_MarkerItem value %d is %s=%lld, want NewEnumerator%d=%d"), I, *Internal, Enum->GetValueByIndex(I), I, I);
				return nullptr;
			}
			Values += FString::Printf(TEXT("%s%d=%s"), I ? TEXT(", ") : TEXT(""), int32(Enum->GetValueByIndex(I)), *Enum->GetDisplayNameTextByIndex(I).ToString());
		}
		UE_LOG(LogCoreGen, Display, TEXT("MARKER enum %s values: %s"), *LongName, *Values);
		return Save(Enum) ? Enum : nullptr;
	}

	struct FMarkerVar
	{
		const TCHAR* Name;
		FEdGraphPinType Type;
		/** Set in the level by the author (instance-editable). False: runtime-only (not editable, transient). */
		bool bEditable = true;
		double Min = 0, Max = 0; // ClampMin/ClampMax when Min < Max
	};

	struct FMarkerKind
	{
		const TCHAR* Kind;
		/** The class has a visible mesh: Preview_S0 shows a box of this size (uu, its base at the marker). Zero: no box. */
		FVector Box = FVector::ZeroVector;
		/** The sprite (an engine editor texture) of the editor-only billboard Icon every kind has. */
		const TCHAR* Icon = nullptr;
		TArray<FMarkerVar> Vars;
		bool bBeginPlay = false;
	};

	/** No collision, no navigation effect, no shadow, editor-only: the cook strips it, so no cooked marker names its mesh. */
	void PreviewOnly(UPrimitiveComponent* C)
	{
		C->bIsEditorOnly = true;
		C->SetCollisionProfileName(UCollisionProfile::NoCollision_ProfileName);
		C->SetCollisionEnabled(ECollisionEnabled::NoCollision);
		C->SetGenerateOverlapEvents(false);
		C->SetCanEverAffectNavigation(false);
		C->SetCastShadow(false);
		C->bCastDynamicShadow = false;
		C->bCastStaticShadow = false;
	}

	USCS_Node* AddComponent(UBlueprint* BP, USCS_Node* Parent, UClass* Class, const FString& Name)
	{
		USCS_Node* N = BP->SimpleConstructionScript->CreateNode(Class, FName(*Name));
		Parent->AddChildNode(N);
		return N;
	}

	/** The SCS's DefaultSceneRoot (CreateBlueprint makes it; reuse it, never add a second one). */
	USCS_Node* SceneRoot(UBlueprint* BP)
	{
		USimpleConstructionScript* SCS = BP->SimpleConstructionScript;
		SCS->ValidateSceneRootNodes();
		if (USCS_Node* Def = SCS->GetDefaultSceneRootNode())
		{
			if (!SCS->GetRootNodes().Contains(Def)) SCS->AddNode(Def);
			return Def;
		}
		USCS_Node* N = SCS->CreateNode(USceneComponent::StaticClass(), USceneComponent::GetDefaultSceneRootVariableName());
		SCS->AddNode(N);
		return N;
	}

	/**
	 * /Game/Mods/<Core>/Map/BP_Marker_<Kind>: an Actor with DefaultSceneRoot, then Preview_S0..S7 (StaticMeshComponent) and
	 * Preview_K0..K1 (SkeletalMeshComponent), all editor-only and empty except Preview_S0's box on kinds with a visible
	 * mesh, then an editor-only billboard Icon (every kind, so all twelve share one component list). Then the kind's
	 * instance-editable settings. No logic: only Start has an (empty) enabled ReceiveBeginPlay, which the map service hooks.
	 */
	UBlueprint* BuildMarker(const FString& MapDir, const FMarkerKind& K)
	{
		const FString Name = FString::Printf(TEXT("BP_Marker_%s"), K.Kind);
		UBlueprint* BP = NewBlueprint(MapDir / Name, AActor::StaticClass(), UBlueprint::StaticClass(), UBlueprintGeneratedClass::StaticClass());
		USCS_Node* Root = SceneRoot(BP);
		for (int32 I = 0; I < NumStaticSlots; ++I)
		{
			USCS_Node* N = AddComponent(BP, Root, UStaticMeshComponent::StaticClass(), FString::Printf(TEXT("Preview_S%d"), I));
			UStaticMeshComponent* C = CastChecked<UStaticMeshComponent>(N->ComponentTemplate);
			PreviewOnly(C);
			if (I == 0 && !K.Box.IsZero())
			{
				UStaticMesh* Box = LoadObject<UStaticMesh>(nullptr, BoxMeshPath);
				UMaterialInterface* Mat = LoadObject<UMaterialInterface>(nullptr, BoxMaterialPath);
				checkf(Box && Mat, TEXT("Engine basic shapes missing (%s)"), BoxMeshPath);
				C->SetStaticMesh(Box);
				C->SetMaterial(0, Mat);
				// The cube is 100 uu, centred: scale it to the box and rest it on the marker's origin.
				C->SetRelativeScale3D(K.Box / 100.0);
				C->SetRelativeLocation(FVector(0, 0, K.Box.Z / 2));
			}
		}
		for (int32 I = 0; I < NumSkeletalSlots; ++I)
		{
			USCS_Node* N = AddComponent(BP, Root, USkeletalMeshComponent::StaticClass(), FString::Printf(TEXT("Preview_K%d"), I));
			PreviewOnly(CastChecked<USkeletalMeshComponent>(N->ComponentTemplate));
		}
		{
			USCS_Node* N = AddComponent(BP, Root, UBillboardComponent::StaticClass(), TEXT("Icon"));
			UBillboardComponent* C = CastChecked<UBillboardComponent>(N->ComponentTemplate);
			UTexture2D* Sprite = LoadObject<UTexture2D>(nullptr, K.Icon);
			checkf(Sprite, TEXT("No editor sprite %s"), K.Icon);
			C->SetSprite(Sprite);
			C->bIsEditorOnly = true;
			C->SetHiddenInGame(true);
		}
		for (const FMarkerVar& V : K.Vars)
		{
			FBlueprintEditorUtils::AddMemberVariable(BP, FName(V.Name), V.Type);
			FBlueprintEditorUtils::SetBlueprintOnlyEditableFlag(BP, FName(V.Name), !V.bEditable);
			if (!V.bEditable) FBlueprintEditorUtils::SetVariableTransientFlag(BP, FName(V.Name), true);
			if (V.Min < V.Max)
			{
				for (const TCHAR* Key : { TEXT("ClampMin"), TEXT("UIMin") }) FBlueprintEditorUtils::SetBlueprintVariableMetaData(BP, FName(V.Name), nullptr, Key, FString::SanitizeFloat(V.Min));
				for (const TCHAR* Key : { TEXT("ClampMax"), TEXT("UIMax") }) FBlueprintEditorUtils::SetBlueprintVariableMetaData(BP, FName(V.Name), nullptr, Key, FString::SanitizeFloat(V.Max));
			}
		}
		UEdGraph* EG = FBlueprintEditorUtils::FindEventGraph(BP);
		ClearGraph(BP, EG);
		if (K.bBeginPlay)
		{
			int32 Y = 0;
			UK2Node_Event* Begin = FKismetEditorUtilities::AddDefaultEventNode(BP, EG, TEXT("ReceiveBeginPlay"), AActor::StaticClass(), Y);
			if (!Begin) { UE_LOG(LogCoreGen, Error, TEXT("%s: no BeginPlay event node"), *Name); return nullptr; }
			Begin->SetEnabledState(ENodeEnabledState::Enabled, false);
		}
		if (!Compile(BP)) return nullptr;
		UClass* C = BP->GeneratedClass;
		const bool bOwnBegin = C->FindFunctionByName(TEXT("ReceiveBeginPlay"), EIncludeSuperFlag::ExcludeSuper) != nullptr;
		if (bOwnBegin != K.bBeginPlay)
		{
			UE_LOG(LogCoreGen, Error, TEXT("%s: own ReceiveBeginPlay=%d, want %d"), *Name, bOwnBegin, K.bBeginPlay);
			return nullptr;
		}
		// The frozen layout, logged so a change shows up in the build log; -Layout= writes it for build.ps1's comparison.
		FString Order;
		for (TFieldIterator<FProperty> It(C, EFieldIteratorFlags::ExcludeSuper); It; ++It) Order += (Order.IsEmpty() ? TEXT("") : TEXT(", ")) + It->GetName();
		FString Comps;
		for (USCS_Node* N : BP->SimpleConstructionScript->GetAllNodes()) Comps += (Comps.IsEmpty() ? TEXT("") : TEXT(", ")) + N->GetVariableName().ToString();
		UE_LOG(LogCoreGen, Display, TEXT("MARKER %s components: %s"), *Name, *Comps);
		UE_LOG(LogCoreGen, Display, TEXT("MARKER %s members: %s"), *Name, *Order);
		return Save(BP) ? BP : nullptr;
	}

	/** The twelve markers and E_MarkerItem under /Game/Mods/<Core>/Map/ (the settings' types follow the demo's BP_DM_*Marker). */
	bool BuildMarkers(const FString& Dir)
	{
		const FString MapDir = Dir / TEXT("Map");
		UUserDefinedEnum* Items = BuildItemEnum(MapDir);
		if (!Items) return false;
		const FEdGraphPinType Str = StrT();
		const FEdGraphPinType Actor = ObjT(AActor::StaticClass());
		const FEdGraphPinType Vec = PinType(UEdGraphSchema_K2::PC_Struct, TBaseStructure<FVector>::Get());
		const TArray<FMarkerKind> Kinds = {
			// GameStartService_C; the map service hooks this class's ReceiveBeginPlay.
			{ TEXT("Start"), FVector::ZeroVector, TEXT("/Engine/EditorResources/S_Player.S_Player"), {}, true },
			// An item lying on the floor.
			{ TEXT("Item"), FVector(30, 30, 30), TEXT("/Engine/EditorResources/S_Actor.S_Actor"), { { TEXT("Item"), PinType(UEdGraphSchema_K2::PC_Byte, Items) } } },
			// One classified intel; markers with the same AreaName make one area. TaskText: the Journal's task text.
			{ TEXT("Intel"), FVector(50, 40, 10), TEXT("/Engine/EditorResources/S_Actor.S_Actor"), { { TEXT("AreaName"), Str }, { TEXT("UniqueIdentifier"), Str }, { TEXT("TaskText"), Str } } },
			// The nuke computer: Landing is the Landing marker the evac flies to; ReinforcementStart a PlayerStart.
			{ TEXT("Computer"), FVector(40, 40, 30), TEXT("/Engine/EditorResources/S_Actor.S_Actor"), { { TEXT("LocationName"), Str }, { TEXT("Landing"), Actor }, { TEXT("ReinforcementStart"), ObjT(APlayerStart::StaticClass()) } } },
			// A generator; Equipment lists the markers it powers.
			{ TEXT("Generator"), FVector(150, 100, 120), TEXT("/Engine/EditorResources/S_Actor.S_Actor"), { { TEXT("LocationName"), Str }, { TEXT("Equipment"), ArrayOf(Actor) } } },
			{ TEXT("Lever"), FVector(20, 20, 120), TEXT("/Engine/EditorResources/S_Trigger.S_Trigger"), {} },
			{ TEXT("EnemySpawner"), FVector::ZeroVector, TEXT("/Engine/EditorResources/S_Pawn.S_Pawn"), {} },
			{ TEXT("EnemyWaypoint"), FVector::ZeroVector, TEXT("/Engine/EditorResources/S_NavP.S_NavP"), {} },
			{ TEXT("Landing"), FVector::ZeroVector, TEXT("/Engine/EditorResources/S_TargetPoint.S_TargetPoint"), {} },
			// The Journal map: Picture (an object path in the map's own pak), its world rectangle; KeepPicture is runtime-only.
			{ TEXT("Map"), FVector::ZeroVector, TEXT("/Engine/EditorResources/S_Note.S_Note"),
				{ { TEXT("Picture"), Str }, { TEXT("RectMin"), Vec }, { TEXT("RectMax"), Vec }, { TEXT("KeepPicture"), ObjT(UTexture2D::StaticClass()), false } } },
			// One area flag on the Journal map.
			{ TEXT("Location"), FVector::ZeroVector, TEXT("/Engine/EditorResources/S_TextRenderActorIcon.S_TextRenderActorIcon"), { { TEXT("LocationName"), Str } } },
			// The sky: StartHour 0..24, the time of day the match starts at.
			{ TEXT("Sky"), FVector::ZeroVector, TEXT("/Engine/EditorResources/S_SkyAtmosphere.S_SkyAtmosphere"), { { TEXT("StartHour"), RealT(), true, 0.0, 24.0 } } },
		};
		check(Kinds.Num() == UE_ARRAY_COUNT(MarkerKinds));
		for (int32 I = 0; I < Kinds.Num(); ++I)
		{
			check(FCString::Strcmp(Kinds[I].Kind, MarkerKinds[I]) == 0);
			if (!BuildMarker(MapDir, Kinds[I])) return false;
		}
		UE_LOG(LogCoreGen, Display, TEXT("MARKER %d markers and E_MarkerItem under %s"), Kinds.Num(), *MapDir);
		return true;
	}

	/** A property's type for the layout: its kind, and the class, struct or enum it names (the core folder as <Core>). */
	FString LayoutType(const FProperty* P, const FString& Dir)
	{
		FString T;
		if (const FArrayProperty* A = CastField<FArrayProperty>(P)) T = TEXT("array<") + LayoutType(A->Inner, Dir) + TEXT(">");
		else if (const FObjectPropertyBase* O = CastField<FObjectPropertyBase>(P)) T = P->GetClass()->GetName() + TEXT("<") + (O->PropertyClass ? O->PropertyClass->GetPathName() : FString(TEXT("?"))) + TEXT(">");
		else if (const FStructProperty* S = CastField<FStructProperty>(P)) T = TEXT("StructProperty<") + S->Struct->GetPathName() + TEXT(">");
		else if (const FByteProperty* B = CastField<FByteProperty>(P)) T = B->Enum ? TEXT("ByteProperty<") + B->Enum->GetPathName() + TEXT(">") : FString(TEXT("ByteProperty"));
		else if (const FEnumProperty* E = CastField<FEnumProperty>(P)) T = TEXT("EnumProperty<") + E->GetEnum()->GetPathName() + TEXT(">");
		else T = P->GetClass()->GetName();
		return T.Replace(*(Dir + TEXT("/")), TEXT("/Game/Mods/<Core>/"), ESearchCase::CaseSensitive);
	}

	/**
	 * The frozen layout of /Game/Mods/<Core>/Map/ as loaded (from memory after a generate, or from disk with -LayoutOnly):
	 * per marker its components in SCS order (name, class, parent, editor-only), its own properties in the class's
	 * property order (which is the order a cooked, unversioned level stores a placed marker's values in), with their
	 * types and flags, and its own functions; then E_MarkerItem's entries (index, internal name, value, display name).
	 * build.ps1 compares these lines with the committed golden file (unreal/map-markers.layout).
	 */
	bool DescribeMarkers(const FString& Dir, TArray<FString>& Out)
	{
		const FString MapDir = Dir / TEXT("Map");
		for (const TCHAR* Kind : MarkerKinds)
		{
			const FString Name = FString::Printf(TEXT("BP_Marker_%s"), Kind);
			UBlueprint* BP = LoadObject<UBlueprint>(nullptr, *(MapDir / Name + TEXT(".") + Name));
			UClass* C = BP ? BP->GeneratedClass.Get() : nullptr;
			if (!C || !BP->SimpleConstructionScript)
			{
				UE_LOG(LogCoreGen, Error, TEXT("LAYOUT %s/%s did not load as a Blueprint class"), *MapDir, *Name);
				return false;
			}
			Out.Add(FString::Printf(TEXT("%s parent %s"), *Name, *BP->ParentClass->GetPathName()));
			int32 I = 0;
			for (USCS_Node* N : BP->SimpleConstructionScript->GetAllNodes())
			{
				FName ParentName = NAME_None;
				for (USCS_Node* P : BP->SimpleConstructionScript->GetAllNodes()) if (P->GetChildNodes().Contains(N)) ParentName = P->GetVariableName();
				const UActorComponent* T = N->ComponentTemplate;
				// The template's settings the spec fixes: collision, navigation, shadow, the box mesh, the icon's sprite.
				FString Extra;
				if (const UPrimitiveComponent* Prim = Cast<UPrimitiveComponent>(T))
				{
					Extra += FString::Printf(TEXT(" collision=%s nav=%d shadow=%d"), *UEnum::GetValueAsString(Prim->GetCollisionEnabled()),
						Prim->CanEverAffectNavigation() ? 1 : 0, Prim->CastShadow ? 1 : 0);
				}
				if (const UStaticMeshComponent* SM = Cast<UStaticMeshComponent>(T))
				{
					Extra += FString::Printf(TEXT(" mesh=%s"), SM->GetStaticMesh() ? *SM->GetStaticMesh()->GetPathName() : TEXT("None"));
				}
				if (const UBillboardComponent* BB = Cast<UBillboardComponent>(T))
				{
					Extra += FString::Printf(TEXT(" sprite=%s"), BB->Sprite ? *BB->Sprite->GetPathName() : TEXT("None"));
				}
				Out.Add(FString::Printf(TEXT("%s component %d %s %s parent=%s editoronly=%d%s"), *Name, I++, *N->GetVariableName().ToString(),
					N->ComponentClass ? *N->ComponentClass->GetName() : TEXT("?"), *ParentName.ToString(), T && T->bIsEditorOnly ? 1 : 0, *Extra));
			}
			I = 0;
			for (TFieldIterator<FProperty> It(C, EFieldIteratorFlags::ExcludeSuper); It; ++It)
			{
				const bool bEdit = It->HasAnyPropertyFlags(CPF_Edit) && !It->HasAnyPropertyFlags(CPF_DisableEditOnInstance);
				FString Extra;
				for (const TCHAR* Key : { TEXT("ClampMin"), TEXT("ClampMax") })
				{
					if (It->HasMetaData(Key)) Extra += FString::Printf(TEXT(" %s=%s"), Key, *It->GetMetaData(Key));
				}
				// The class default (exported text, the core folder as <Core>): what an unset placed marker reads.
				FString Default;
				It->ExportTextItem_InContainer(Default, C->GetDefaultObject(), nullptr, nullptr, PPF_None);
				Default.ReplaceInline(TEXT("\r"), TEXT(" "));
				Default.ReplaceInline(TEXT("\n"), TEXT(" "));
				Default.ReplaceInline(*(Dir + TEXT("/")), TEXT("/Game/Mods/<Core>/"), ESearchCase::CaseSensitive);
				Out.Add(FString::Printf(TEXT("%s member %d %s %s edit=%d transient=%d%s default=\"%s\""), *Name, I++, *It->GetName(), *LayoutType(*It, Dir),
					bEdit ? 1 : 0, It->HasAnyPropertyFlags(CPF_Transient) ? 1 : 0, *Extra, *Default));
			}
			TArray<FString> Fns;
			for (TFieldIterator<UFunction> It(C, EFieldIteratorFlags::ExcludeSuper); It; ++It) Fns.Add(It->GetName());
			Fns.Sort();
			for (const FString& F : Fns) Out.Add(FString::Printf(TEXT("%s function %s"), *Name, *F.Replace(*Name, TEXT("<Self>"), ESearchCase::CaseSensitive)));
		}
		UUserDefinedEnum* Enum = LoadObject<UUserDefinedEnum>(nullptr, *(MapDir / TEXT("E_MarkerItem.E_MarkerItem")));
		if (!Enum)
		{
			UE_LOG(LogCoreGen, Error, TEXT("LAYOUT %s/E_MarkerItem did not load"), *MapDir);
			return false;
		}
		for (int32 I = 0; I < Enum->NumEnums(); ++I)
		{
			Out.Add(FString::Printf(TEXT("E_MarkerItem entry %d %s %lld \"%s\""), I, *Enum->GetNameStringByIndex(I), Enum->GetValueByIndex(I),
				I < Enum->NumEnums() - 1 ? *Enum->GetDisplayNameTextByIndex(I).ToString() : TEXT("-")));
		}
		return true;
	}

	/** -Layout=<file>: the layout lines (DescribeMarkers), one per line. */
	bool WriteLayout(const FString& Dir, const FString& File)
	{
		TArray<FString> Lines;
		if (!DescribeMarkers(Dir, Lines)) return false;
		if (!FFileHelper::SaveStringArrayToFile(Lines, *File))
		{
			UE_LOG(LogCoreGen, Error, TEXT("LAYOUT could not write %s"), *File);
			return false;
		}
		UE_LOG(LogCoreGen, Display, TEXT("LAYOUT %d lines for %s/Map -> %s"), Lines.Num(), *Dir, *File);
		return true;
	}
}

UCoreGenCommandlet::UCoreGenCommandlet()
{
	IsClient = false;
	IsServer = false;
	IsEditor = true;
	LogToConsole = true;
	ShowErrorCount = true;
}

int32 UCoreGenCommandlet::Main(const FString& Params)
{
	FString Core;
	if (!FParse::Value(*Params, TEXT("CoreName="), Core) || Core.IsEmpty())
	{
		UE_LOG(LogCoreGen, Error, TEXT("Pass -CoreName=<mod.json name>"));
		return 1;
	}
	const FString Dir = TEXT("/Game/Mods/") + Core;
	FString LayoutFile;
	FParse::Value(*Params, TEXT("Layout="), LayoutFile);
	// -LayoutOnly: write the layout of the markers already on disk (build.ps1 checks the author template's copies this way).
	if (FParse::Param(*Params, TEXT("LayoutOnly")))
	{
		if (LayoutFile.IsEmpty()) { UE_LOG(LogCoreGen, Error, TEXT("-LayoutOnly needs -Layout=<file>")); return 1; }
		return WriteLayout(Dir, LayoutFile) ? 0 : 1;
	}
	// Core story 24: the icons first (their own folder, Icons/), then the widgets; no widget references a texture.
	FString IconDir;
	FParse::Value(*Params, TEXT("IconDir="), IconDir);
	if (!BuildIcons(Dir, IconDir)) return 1;
	if (!BuildText(Dir, Core)) return 1;
	if (!BuildPanel(Dir, Core)) return 1;
	if (!BuildButton(Dir, Core)) return 1;
	if (!BuildList(Dir, Core)) return 1;
	if (!BuildRow(Dir, Core)) return 1;
	if (!BuildScreen(Dir, Core)) return 1;
	if (!BuildImage(Dir, Core)) return 1;
	if (!BuildActor(Dir, Core)) return 1;
	if (!BuildMarkers(Dir)) return 1;
	if (!LayoutFile.IsEmpty() && !WriteLayout(Dir, LayoutFile)) return 1;
	UE_LOG(LogCoreGen, Display, TEXT("CoreGen: all assets for %s generated."), *Core);
	return 0;
}
