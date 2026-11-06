#include "CoreGenCommandlet.h"

#include "AssetRegistry/AssetRegistryModule.h"
#include "Blueprint/SlateBlueprintLibrary.h"
#include "Blueprint/UserWidget.h"
#include "Blueprint/WidgetBlueprintGeneratedClass.h"
#include "Blueprint/WidgetTree.h"
#include "Components/BillboardComponent.h"
#include "Components/Border.h"
#include "Components/Button.h"
#include "Components/ButtonSlot.h"
#include "Components/BorderSlot.h"
#include "Components/HorizontalBox.h"
#include "Components/Overlay.h"
#include "Components/OverlaySlot.h"
#include "Components/SkeletalMeshComponent.h"
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

	/**
	 * WBP_<Core>Text: Border "Background" -> TextBlock "Text" (white, drop shadow, size 18), and three functions:
	 *   SetText(NewText: String)                  Text.SetText(NewText)
	 *   SetBackground(R, G, B, A: Float)          Background.SetBrushColor((R, G, B, A)); A = 0 shows no box
	 *   SetBackgroundPadding(Padding: Float)      Background.SetPadding(Padding on all four sides)
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
		for (const TCHAR* Fn : {TEXT("SetText"), TEXT("SetBackground"), TEXT("SetBackgroundPadding")})
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
		if (!Compile(WBP)) return nullptr;
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
	 */
	UWidgetBlueprint* BuildPanel(const FString& Dir, const FString& Core)
	{
		UWidgetBlueprint* WBP = CastChecked<UWidgetBlueprint>(NewBlueprint(Dir / FString::Printf(TEXT("WBP_%sPanel"), *Core),
			UUserWidget::StaticClass(), UWidgetBlueprint::StaticClass(), UWidgetBlueprintGeneratedClass::StaticClass()));
		CheckNames({TEXT("SetBackground"), TEXT("SetBackgroundPadding"), TEXT("SetTag")});

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
		if (!Compile(WBP)) return nullptr;
		FillBackground(WBP, SetBg, SetPad);
		FillTag(WBP, SetTag);
		if (!Compile(WBP) || !Save(WBP)) return nullptr;
		return WBP;
	}

	/**
	 * WBP_<Core>Button (story 15): Button "Btn" -> TextBlock "Label" (white, drop shadow, size 18, centred). Functions:
	 *   SetLabel(NewLabel: String)          Label.SetText(NewLabel)
	 *   SetEnabledState(Enabled: Bool)      Btn.SetIsEnabled(Enabled) (a disabled button never fires OnClicked)
	 *   SetColors(NR, NG, NB, NA, HR, HG, HB, HA, PR, PG, PB, PA, Padding: Float)
	 *                                       Btn.SetStyle: a solid brush per state (normal and disabled N, hovered H,
	 *                                       pressed P) and the same padding all round in both padding slots
	 *   SetTag(NewTag: String)              CoreTag = NewTag
	 *   <Core>_OnClicked()                  ClickCount += 1. The button's OnClicked calls it and nothing else; each
	 *                                       dependent's Lua post-hooks it by full path (bp-spike's NNSpike_OnClicked)
	 * Lua draws it disabled at the theme's opacity (SetRenderOpacity on the widget).
	 */
	UWidgetBlueprint* BuildButton(const FString& Dir, const FString& Core)
	{
		UWidgetBlueprint* WBP = CastChecked<UWidgetBlueprint>(NewBlueprint(Dir / FString::Printf(TEXT("WBP_%sButton"), *Core),
			UUserWidget::StaticClass(), UWidgetBlueprint::StaticClass(), UWidgetBlueprintGeneratedClass::StaticClass()));
		const FString ClickFn = Core + TEXT("_OnClicked");
		CheckNames({TEXT("SetLabel"), TEXT("SetEnabledState"), TEXT("SetColors"), TEXT("SetTag"), *ClickFn});

		UWidgetTree* T = WBP->WidgetTree;
		UButton* Btn = T->ConstructWidget<UButton>(UButton::StaticClass(), TEXT("Btn"));
		Btn->bIsVariable = true;
		T->RootWidget = Btn;
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
		UButtonSlot* LabelSlot = CastChecked<UButtonSlot>(Btn->AddChild(Label));
		LabelSlot->SetPadding(FMargin(0.f));
		LabelSlot->SetHorizontalAlignment(HAlign_Center);
		LabelSlot->SetVerticalAlignment(VAlign_Center);
		WBP->OnVariableAdded(TEXT("Btn"));
		WBP->OnVariableAdded(TEXT("Label"));
		FBlueprintEditorUtils::AddMemberVariable(WBP, TEXT("ClickCount"), IntT(), TEXT("0"));

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
		if (!Compile(WBP)) return nullptr;
		FillTag(WBP, SetTag);
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
			G.Chain({SetColors.Entry, Set});
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
		}

		if (!Compile(WBP) || !Save(WBP)) return nullptr;
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
	if (!BuildText(Dir, Core)) return 1;
	if (!BuildPanel(Dir, Core)) return 1;
	if (!BuildButton(Dir, Core)) return 1;
	if (!BuildActor(Dir, Core)) return 1;
	if (!BuildMarkers(Dir)) return 1;
	if (!LayoutFile.IsEmpty() && !WriteLayout(Dir, LayoutFile)) return 1;
	UE_LOG(LogCoreGen, Display, TEXT("CoreGen: all assets for %s generated."), *Core);
	return 0;
}
